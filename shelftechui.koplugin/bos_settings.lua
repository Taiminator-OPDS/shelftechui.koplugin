--[[
The Settings app: KOReader's menus as one full-screen app, in Bookshelf's
design language: a card per menu (Navigation, Typesetting, Settings, Tools…),
plus ShelfTechUI's own page.

It is how settings open everywhere:
  * on Bookshelf home / the file browser: the ⚙ chip, swiping down from the
    top, the menu key;
  * in a book: "All settings" in
    Quick Settings, the menu key. (Swiping down in a book opens Quick
    Settings.)
KOReader's menu itself is left intact: other plugins and Bookshelf's start
menu still find every item where they expect it. Menu search results open in
the app, on the right page.
--]]

local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local TouchMenu = require("ui/widget/touchmenu")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local PLUGIN_DIR = (debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*$", "%1"))
local ICON_NAME = "bookshelfos.settings"
local ICON_FILE = PLUGIN_DIR .. "/icons/settings.svg"

-- Tabs have an icon but no title, so name them ourselves (keyed by tab id).
local TAB_NAMES = {
    filemanager_settings = _("File browser"),
    filemanager = _("File browser"),
    setting = _("Settings"),
    navi = _("Navigation"),
    typeset = _("Typesetting"),
    tools = _("Tools"),
    search = _("Search"),
    main = _("Main menu"),
    reader = _("Resume reading"),
    plus_menu = _("Plus menu"),
}

local Settings = {}
Settings.__index = Settings
Settings.instances = setmetatable({}, { __mode = "k" }) -- ui -> instance

--- The instance of the topmost UI on screen (the reader, or the file manager
--- Bookshelf home lives in).
function Settings.top()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local inst = Settings.instances[stack[i].widget]
        if inst then return inst end
    end
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ui = (ReaderUI and ReaderUI.instance) or (FileManager and FileManager.instance)
    return ui and Settings.instances[ui]
end

-- ---------------------------------------------------------------------------
-- One-time patches
-- ---------------------------------------------------------------------------

-- The app's icon, resolvable by name from the plugin folder.
local function installIconResolver()
    local IconWidget = require("ui/widget/iconwidget")
    if IconWidget._bos_icons then return end
    IconWidget._bos_icons = true
    local orig_init = IconWidget.init
    IconWidget.init = function(self, ...)
        if self.icon == ICON_NAME and not self.file and not self.image then
            self.file = ICON_FILE
        end
        return orig_init(self, ...)
    end
end

-- Menu search results (TouchMenu:openMenu("2.3.1")) open in the app.
local function patchMenuSearch()
    if TouchMenu._bos_search then return end
    TouchMenu._bos_search = true
    local orig_open = TouchMenu.openMenu
    TouchMenu.openMenu = function(menu, path, ...)
        local s = Settings.top()
        local tabs = menu.tab_item_table
        if s and type(path) == "string" and type(tabs) == "table" then
            local parts = {}
            for part in path:gmatch("[^%.]+") do table.insert(parts, tonumber(part)) end
            local tab_nb = table.remove(parts, 1)
            if tab_nb and tabs[tab_nb] then
                pcall(function() if menu.closeMenu then menu:closeMenu() end end)
                s:openAt(tabs[tab_nb], parts)
                return
            end
        end
        return orig_open(menu, path, ...)
    end
end

-- Bookshelf's "instant close" leaves the book open under the shelf (parked)
-- with no file browser behind it. A swipe or tap at the top of home then goes
-- through Bookshelf's Park.finishToMenu, which closes the book and opens
-- KOReader's file-browser menu directly, past the swipe setting (the stock
-- menu dropping down "sometimes": after a book was closed). Send it to the
-- chosen target instead.
function Settings.homeSwipeAction()
    local target = require("bos_settings_store").get("home_swipe")
    if target == "summary" then
        return function() require("bos_summary").show() end
    elseif target == "settings" then
        return function()
            local s = Settings.top()
            if s then s:showHome() end
        end
    end
end

local function patchParkMenu()
    local Park = package.loaded["lib/bookshelf_reader_park"]
    if not Park then
        local ok, mod = pcall(require, "lib/bookshelf_reader_park")
        Park = ok and type(mod) == "table" and mod or nil
    end
    if not Park or Park._bos_menu or type(Park.finishToMenu) ~= "function" then return end
    Park._bos_menu = true
    local orig = Park.finishToMenu
    Park.finishToMenu = function(...)
        local action = Settings.homeSwipeAction()
        if not action then return orig(...) end
        local FMM = require("apps/filemanager/filemanagermenu")
        local orig_show = FMM.onShowMenu
        local redirected = false
        FMM.onShowMenu = function(m, tab_index, do_not_show)
            if do_not_show then return orig_show(m, tab_index, do_not_show) end
            redirected = true
            return true
        end
        local res = table.pack(pcall(orig, ...))
        FMM.onShowMenu = orig_show
        if redirected then UIManager:nextTick(action) end
        if not res[1] then error(res[2], 0) end
        return unpack(res, 2, res.n)
    end
end
Settings._patchParkMenu = patchParkMenu

-- ---------------------------------------------------------------------------
-- Per UI (file manager / reader)
-- ---------------------------------------------------------------------------

function Settings.attach(ui)
    installIconResolver()
    patchMenuSearch()
    pcall(patchParkMenu)
    local self = setmetatable({ ui = ui }, Settings)
    Settings.instances[ui] = self
    if ui.menu then self:wrapMenuOpeners(ui.menu) end
    return self
end

--- Swiping down from the top (or tapping there): in a book, Quick Settings;
--- on home, the reading summary (both changeable in Settings → ShelfTechUI,
--- including "KOReader's menu", which leaves KOReader's own pull-down). The
--- menu key always opens the Settings app.
function Settings:wrapMenuOpeners(menu)
    if menu._bos_openers then return end
    menu._bos_openers = true
    local s = self
    local Store = require("bos_settings_store")
    local reading = self.ui.document ~= nil
    local function target()
        if reading then return Store.get("reader_swipe") end
        return Store.get("home_swipe")
    end
    local ACTIONS = {
        qs = function() require("bos_quicksettings").show() end,
        summary = function() require("bos_summary").show() end,
        settings = function() s:showHome() end,
    }
    local function wrap(name, wanted, action_for)
        local orig = menu[name]
        if type(orig) ~= "function" then return end
        menu[name] = function(m, ...)
            local action = action_for()
            if action and wanted(m, ...) then
                action()
                return true
            end
            return orig(m, ...)
        end
    end
    local function swipeAction() return ACTIONS[target()] end
    local function appAction() return ACTIONS.settings end
    wrap("onTapShowMenu", function(m) return m.activation_menu ~= "swipe" end, swipeAction)
    wrap("onSwipeShowMenu", function(m, ges)
        if m.activation_menu ~= "tap" and ges and ges.direction == "south" then
            if m.ui and m.ui.document then
                m.ui:handleEvent(Event:new("HandledAsSwipe")) -- cancel any pan scroll
            end
            return true
        end
        return false
    end, swipeAction)
    wrap("onPressMenu", function() return true end, appAction)
    wrap("onKeyPressShowMenu", function() return true end, appAction)
end

function Settings:onCloseWidget()
    self:closeHub()
    Settings.instances[self.ui] = nil
end

function Settings:onSetDimensions()
    if self.screen then
        self:closeHub()
        UIManager:nextTick(function() self:showHome() end)
    end
end

-- ---------------------------------------------------------------------------
-- What the app shows
-- ---------------------------------------------------------------------------

function Settings:getIcon() return ICON_NAME end

function Settings:tabs()
    local menu = self.ui.menu
    if not menu then return {} end
    if menu.tab_item_table == nil then menu:setUpdateItemTable() end
    return menu.tab_item_table or {}
end

function Settings:tabName(tab)
    return TAB_NAMES[tab.id] or tab.text or _("Menu")
end

--- The app's sections (its chip strip): ShelfTechUI first, then each
--- KOReader menu that has items.
--- { id, name, items = table | nil, callback = fn | nil }
function Settings:getSections()
    -- one Settings app, by what things are for (not by which plugin or
    -- KOReader menu they come from): KOReader's own menus are folded into
    -- the section they belong to, under a heading
    local ok, sections = pcall(function() return require("bos_settings_page").sections(self) end)
    if ok and sections then return sections end
    logger.warn("ShelfTechUI: settings sections failed, showing the plain ones:", sections)
    sections = {
        { id = "bookshelfos", name = _("ShelfTechUI"), icon = "book.opened",
          items = require("bos_settings_page").items(self) },
        { id = "stui_themes", name = _("Themes"), icon = "appbar.contrast",
          items = require("bos_settings_page").themeItems() },
    }
    for _i, tab in ipairs(self:tabs()) do
        local count = 0
        for _j, it in ipairs(tab) do
            if it.text ~= "KOMenu:separator" then count = count + 1 end
        end
        if count > 0 then
            table.insert(sections, { id = tostring(tab.id or tab.icon or _i), name = self:tabName(tab),
                icon = tab.icon, items = tab })
        end
    end
    return sections
end

-- ---------------------------------------------------------------------------
-- The app
-- ---------------------------------------------------------------------------

function Settings:showHome()
    -- a screen closed some other way (a plugin closing windows, a restart of
    -- the file browser) is gone: start afresh
    if self.screen then
        local live = false
        for _i, w in ipairs(UIManager._window_stack or {}) do
            if w.widget == self.screen then live = true break end
        end
        if live then return end
        self.screen = nil
    end
    if not self.ui.menu then
        UIManager:show(InfoMessage:new{ text = _("Settings aren't available here.") })
        return
    end
    local Screen = require("bos_settings_ui")
    self.screen = Screen:new{ plugin = self }
    UIManager:show(self.screen)
end

--- Open the app on a menu, walking `path` (item indexes) into it.
function Settings:openAt(tab, path)
    self:showHome()
    if self.screen then
        self.screen:openPath(tab, path or {})
    end
end

function Settings:closeHub()
    local screen = self.screen
    if screen then
        self.screen = nil
        UIManager:close(screen)
    end
end

--- Open the Settings app of the UI on screen.
function Settings.open()
    -- At home with a book still kept open under it (Bookshelf's parking),
    -- the UI in charge is the book's: its Settings would be the reader's.
    -- Finish closing the book first (as Bookshelf does for its own menus),
    -- then open home's.
    local Park = package.loaded["lib/bookshelf_reader_park"]
    if type(Park) == "table" and Park.isParked and Park.isParked() and not Settings._finishing then
        Settings._finishing = true
        local ok = pcall(Park.runInFileManager, function() end)
        Settings._finishing = false
        if ok then
            UIManager:nextTick(function() Settings.open() end)
            return
        end
    end
    local s = Settings.top()
    if not s then
        logger.warn("ShelfTechUI: no UI to open the Settings app in")
        return
    end
    s:showHome()
end

return Settings
