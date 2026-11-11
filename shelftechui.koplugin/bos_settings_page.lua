--[[
ShelfTechUI's section of the Settings app. Every option says what it does,
in a line of grey under it.

    HOME
      Status bar ›             which chips, their order, long-press
      Swipe down on home ›     reading summary / settings / KOReader's menu
      Reading summary ›        what the summary shows
    IN A BOOK
      Quick Settings ›         which tiles, their order, long-press, sliders
      Swipe down in a book ›   Quick Settings / settings / KOReader's menu
      Reading toolbar ›        what opens it, what it shows
      Text sheet               ShelfTechUI's Aa sheet, or KOReader's own
    ABOUT
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local Controls = require("bos_controls")
local Store = require("bos_settings_store")
local UI = require("bos_ui")
local S = UI.S

local Page = {}

Page.VERSION = "1.5.3"

-- Dispatcher's sub-menus edit tables in place and flag `caller.updated`.
local saver = setmetatable({}, { __newindex = function() Store.save() end })

local function readerToolbar()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local ui = ReaderUI and ReaderUI.instance
    return ui and ui.bookshelfos and ui.bookshelfos.toolbar
end

local function refreshHome()
    UIManager:nextTick(function() require("bos_home").refresh() end)
end

--- A radio page: choices = { { key, text, description }, ... }.
local function radios(key, choices, on_change)
    local items = {}
    for _i, c in ipairs(choices) do
        table.insert(items, {
            text = c.text,
            description = c.description,
            right_widget_func = c.widget,
            radio = true,
            checked_func = function() return Store.get(key) == c.key end,
            callback = function()
                Store.set(key, c.key)
                if on_change then on_change(c.key) end
            end,
        })
    end
    return items
end

local function choiceName(key, choices)
    local v = Store.get(key)
    for _i, c in ipairs(choices) do if c.key == v then return c.short or c.text end end
end

-- ---------------------------------------------------------------------------
-- Bookshelf's start menu (≡): every entry, to move or remove -- the same as
-- holding one in the menu, from here too
-- ---------------------------------------------------------------------------

local function smModel()
    local ok, Model = pcall(require, "lib/bookshelf_start_menu_model")
    if ok and type(Model) == "table" and Model.load then return Model end
end

local function smLabel(e)
    if e.type == "divider" then return _("— Divider —") end
    if e.type == "module" then
        local ok, Mods = pcall(require, "lib/bookshelf_start_menu_modules")
        local t = ok and Mods.title and Mods.title(e.module)
        return t or e.module or _("Module")
    end
    return e.label or "?"
end

local function startMenuItems()
    local Model = smModel()
    if not Model then return { { text = _("Bookshelf isn't loaded."), enabled = false } } end
    local items = {}
    local function entryPage(e)
        local function act(fn)
            return function(tm)
                local list = Model.load()
                fn(list)
                Model.save(list)
                if tm and tm.backToUpperMenu then tm:backToUpperMenu() end
                if tm and tm.updateItems then tm:updateItems() end
            end
        end
        return {
            { text = _("Move up"), keep_menu_open = true, callback = act(function(list) Model.moveBy(list, e.id, -1) end) },
            { text = _("Move down"), keep_menu_open = true, callback = act(function(list) Model.moveBy(list, e.id, 1) end) },
            { text = _("Remove from the start menu"), separator = true, keep_menu_open = true,
              callback = act(function(list) Model.removeById(list, e.id) end) },
        }
    end
    local function add(e, depth)
        local label = smLabel(e)
        if depth > 0 then label = "    " .. label end
        table.insert(items, {
            text = label,
            description = e.type == "folder" and _("A folder; removing it removes what's in it.") or nil,
            sub_item_table_func = function() return entryPage(e) end,
        })
        if e.type == "folder" then
            for _j, c in ipairs(e.children or {}) do add(c, depth + 1) end
        end
    end
    local ok, list = pcall(Model.load)
    for _i, e in ipairs(ok and list or {}) do add(e, 0) end
    if #items == 0 then table.insert(items, { text = _("The start menu is empty."), enabled = false }) end
    table.insert(items, 1, { heading = _("Tap an entry to move or remove it") })
    return items
end

local function toggle(key, text, description, on_change, extra)
    local item = {
        text = text,
        description = description,
        checked_func = function() return Store.get(key) ~= false end,
        callback = function()
            Store.set(key, Store.get(key) == false)
            if on_change then on_change() end
        end,
    }
    for k, v in pairs(extra or {}) do item[k] = v end
    return item
end

-- ---------------------------------------------------------------------------
-- A small page with the area that opens the reading toolbar shaded
-- ---------------------------------------------------------------------------

local ZoneIcon = require("ui/widget/widget"):extend{ zone = "medium" }

local ZONE_FRAC = { narrow = { 1/3, 1/3 }, medium = { 1/4, 1/2 }, wide = { 1/8, 3/4 } }

function ZoneIcon:getSize() return Geom:new{ w = S(30), h = S(40) } end

function ZoneIcon:paintTo(bb, x, y)
    local w, h = S(30), S(40)
    local t = math.max(1, S(1.5))
    bb:paintRect(x, y, w, h, UI.BLACK)
    bb:paintRect(x + t, y + t, w - 2 * t, h - 2 * t, UI.WHITE)
    local f = ZONE_FRAC[self.zone]
    if f then
        bb:paintRect(x + math.floor(w * f[1]), y + math.floor(h / 8), math.floor(w * f[2]),
            math.floor(h * 3 / 4), UI.DARK)
    end
    if self.edges then
        bb:paintRect(x + t, y + t, w - 2 * t, math.floor(h / 8), UI.LIGHT)
        bb:paintRect(x + t, y + h - t - math.floor(h / 8), w - 2 * t, math.floor(h / 8), UI.LIGHT)
    end
end

-- ---------------------------------------------------------------------------
-- Choosing controls (home chips / Quick Settings tiles)
-- ---------------------------------------------------------------------------

local SURFACE = {
    home = { thing = _("chip"), things = _("chips"),
             defaults = _("Light, Wi-Fi and Settings."),
             after = refreshHome },
    qs = { thing = _("tile"), things = _("tiles"),
           defaults = _("Wi-Fi, Night, Rotate and Refresh.") },
}

local function holdPage(surface, c)
    local holds = Controls.holds(surface)
    local default_name = c.hold and c.hold["name_" .. surface]
    local sub = {
        {
            text = default_name and T(_("Default: %1"), default_name) or _("Default: nothing"),
            description = _("What this control does on its own when you hold it."),
            radio = true,
            checked_func = function()
                local t = holds[c.id]
                if type(t) ~= "table" then return true end
                for k, _v in pairs(t) do if k ~= "settings" then return false end end
                return true
            end,
            callback = function()
                holds[c.id] = nil
                Store.save()
            end,
            separator = true,
        },
        { heading = _("Or any KOReader action") },
    }
    local picks = {}
    Dispatcher:addSubMenu(saver, picks, holds, c.id)
    -- keep the categories: drop "Nothing" (that's "Default" here) and the
    -- trailing Execute / QuickMenu entries, which don't apply to a long-press
    local cut
    for i, item in ipairs(picks) do
        if item.text_func and i > 1 then cut = i break end
    end
    if cut then for i = #picks, cut, -1 do table.remove(picks, i) end end
    table.remove(picks, 1)
    for _i, item in ipairs(picks) do table.insert(sub, item) end
    return sub
end

local function arrange(surface)
    local SortWidget = require("ui/widget/sortwidget")
    local list = {}
    for _i, c in ipairs(Controls.shown(surface)) do
        table.insert(list, { text = c.spacer and ("\u{2014}\u{2014}  " .. _("Spacer") .. "  \u{2014}\u{2014}") or c.name,
                             orig_item = c.id })
    end
    if #list < 2 then
        UIManager:show(InfoMessage:new{ text = T(_("Add at least two %1 first."), SURFACE[surface].things) })
        return
    end
    UIManager:show(SortWidget:new{
        title = surface == "home" and _("Order of the chips (left to right)")
                                   or _("Order of the tiles (left to right, top to bottom)"),
        item_table = list,
        callback = function()
            local ids = {}
            for _i, it in ipairs(list) do table.insert(ids, it.orig_item) end
            -- chosen but unavailable here keep their place at the end
            for _i, id in ipairs(Controls.ids(surface)) do
                local found = false
                for _j, x in ipairs(ids) do if x == id then found = true end end
                if not found then table.insert(ids, id) end
            end
            Controls.setIds(surface, ids)
            if SURFACE[surface].after then SURFACE[surface].after() end
        end,
    })
end


-- ---------------------------------------------------------------------------
-- Your own shortcuts: a plugin's menu entry, or any KOReader action
-- ---------------------------------------------------------------------------

local SURFACE_NAME = { home = _("Home chips"), qs = _("Quick Settings tiles") }

local function afterAll()
    refreshHome()
end

local function addTo(surface, id)
    if not Controls.isOn(surface, id) then Controls.toggle(surface, id) end
    afterAll()
end

local function glyphWidget(key)
    return function()
        local TextWidget = require("ui/widget/textwidget")
        return TextWidget:new{ text = UI.GLYPH[key] or "", face = UI.symbolFace(UI.ptForPx(S(22))) }
    end
end

local function customPage(d)
    local sub = {
        {
            text = _("Name"),
            description = _("What the chip or tile says. Empty: the plugin's or action's own name."),
            mandatory_func = function() return Controls.customName(d) end,
            keep_menu_open = true,
            callback = function(tm)
                local InputDialog = require("ui/widget/inputdialog")
                local dlg
                dlg = InputDialog:new{
                    title = _("Shortcut name"),
                    input = d.name or "",
                    input_hint = Controls.customName(d),
                    buttons = { {
                        { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                        { text = _("Save"), is_enter_default = true, callback = function()
                            local v = dlg:getInputText()
                            d.name = (v and v ~= "") and v or nil
                            Store.save()
                            UIManager:close(dlg)
                            afterAll()
                            if tm then tm:updateItems() end
                        end },
                    } },
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
        },
        {
            text = _("Icon"),
            description = _("The symbol on the chip or tile."),
            right_widget_func = glyphWidget(d.glyph or "puzzle"),
            sub_item_table_func = function()
                local icons = {}
                for _i, key in ipairs(Controls.GLYPHS) do
                    table.insert(icons, {
                        text = key:gsub("^%l", string.upper),
                        right_widget_func = glyphWidget(key),
                        radio = true,
                        checked_func = function() return (d.glyph or "puzzle") == key end,
                        callback = function() d.glyph = key Store.save() afterAll() end,
                    })
                end
                return icons
            end,
        },
    }
    if d.kind == "action" then
        table.insert(sub, {
            text = _("Action"),
            description = _("What tapping it does: any KOReader action, including the ones plugins add."),
            mandatory_func = function() return Controls.actionName(d.action) or _("none") end,
            sub_item_table_func = function()
                local picks = {}
                local caller = setmetatable({}, { __newindex = function() Store.save() afterAll() end })
                Dispatcher:addSubMenu(caller, picks, d, "action")
                local cut
                for i, item in ipairs(picks) do
                    if item.text_func and i > 1 then cut = i break end
                end
                if cut then for i = #picks, cut, -1 do table.remove(picks, i) end end
                table.remove(picks, 1) -- "Nothing"
                return picks
            end,
        })
    else
        table.insert(sub, {
            text = _("Plugin"),
            description = _("Tap runs its entry in KOReader's menu (or opens its page here). Hold does what holding the entry does, often its settings."),
            mandatory = d.plugin_name or d.plugin,
            enabled = false,
        })
    end
    table.insert(sub, { heading = _("Where it shows") })
    for _i, surface in ipairs{ "home", "qs" } do
        table.insert(sub, {
            text = SURFACE_NAME[surface],
            checked_func = function() return Controls.isOn(surface, d.id) end,
            callback = function() Controls.toggle(surface, d.id) afterAll() end,
        })
    end
    table.insert(sub, {
        text = _("Remove this shortcut"),
        separator = false,
        keep_menu_open = true,
        callback = function(tm)
            UIManager:show(ConfirmBox:new{
                text = T(_("Remove the shortcut \"%1\"?"), Controls.customName(d)),
                ok_text = _("Remove"),
                ok_callback = function()
                    Controls.removeCustom(d.id)
                    afterAll()
                    if tm and tm.backToUpperMenu then tm:backToUpperMenu() end
                end,
            })
        end,
    })
    return sub
end

local function newPluginPage(surface)
    local list = Controls.pluginEntries()
    local sub = {}
    for _i, e in ipairs(list) do
        table.insert(sub, {
            text = e.name,
            description = e.plugin and T(_("From the %1 plugin."), e.plugin) or nil,
            keep_menu_open = true,
            callback = function(tm)
                local d = Controls.newCustom{ kind = "plugin", plugin = e.key, plugin_name = e.name }
                addTo(surface, d.id)
                UIManager:show(InfoMessage:new{ timeout = 2,
                    text = T(_("%1 added to the %2."), e.name, SURFACE_NAME[surface]:lower()) })
                if tm and tm.backToUpperMenu then tm:backToUpperMenu() end
            end,
        })
    end
    if #sub == 0 then
        table.insert(sub, { text = _("No plugins with a menu entry here."), enabled = false })
    end
    return sub
end

local function newActionPage(surface)
    local pending = { action = nil }
    local picks = {}
    local caller = setmetatable({}, { __newindex = function()
        if type(pending.action) == "table" and next(pending.action) ~= nil then
            local d = Controls.newCustom{ kind = "action", action = pending.action }
            pending.action = nil
            addTo(surface, d.id)
            UIManager:show(InfoMessage:new{ timeout = 2,
                text = T(_("%1 added to the %2."), Controls.customName(d), SURFACE_NAME[surface]:lower()) })
        end
    end })
    Dispatcher:addSubMenu(caller, picks, pending, "action")
    local cut
    for i, item in ipairs(picks) do
        if item.text_func and i > 1 then cut = i break end
    end
    if cut then for i = #picks, cut, -1 do table.remove(picks, i) end end
    table.remove(picks, 1)
    return picks
end

local function customItems(surface)
    local items = {
        { heading = _("Your own shortcuts") },
        {
            text = _("Add a plugin…"),
            description = _("Any plugin with an entry in KOReader's menu. Tap runs it; hold opens what holding its entry does (often its settings)."),
            page_title = _("Add a plugin"),
            sub_item_table_func = function() return newPluginPage(surface) end,
        },
        {
            text = _("Add a KOReader action…"),
            description = _("Any action KOReader or a plugin offers for gestures, as a shortcut."),
            page_title = _("Add an action"),
            sub_item_table_func = function() return newActionPage(surface) end,
        },
        {
            text = _("Edit your shortcuts"),
            description = _("Name, icon, action, where each shows, or remove it."),
            mandatory_func = function() return tostring(#Controls.customs()) end,
            sub_item_table_func = function()
                local sub = {}
                for _i, d in ipairs(Controls.customs()) do
                    table.insert(sub, {
                        text = Controls.customName(d),
                        right_widget_func = glyphWidget(d.glyph or "puzzle"),
                        page_title = Controls.customName(d),
                        sub_item_table_func = function() return customPage(d) end,
                    })
                end
                if #sub == 0 then
                    table.insert(sub, { text = _("No shortcuts of your own yet."), enabled = false })
                end
                return sub
            end,
        },
    }
    return items
end

local function controlItems(surface)
    local spec = SURFACE[surface]
    local items = {}
    table.insert(items, { heading = T(_("%1 (tap to add or remove)"), spec.things:gsub("^%l", string.upper)) })
    for _i, c in ipairs(Controls.candidates(surface)) do
        local ok, avail = pcall(c.available)
        table.insert(items, {
            text = c.name,
            description_func = function()
                local d = c.says and c.says[surface] or ""
                if Controls.isOn(surface, c.id) then
                    d = d .. " " .. T(_("Hold: %1."), Controls.holdName(surface, c))
                end
                if not (ok and avail) then
                    d = d .. " " .. (surface == "qs" and _("(Only in a book.)") or _("(Not on this device.)"))
                end
                return d
            end,
            checked_func = function() return Controls.isOn(surface, c.id) end,
            callback = function()
                Controls.toggle(surface, c.id)
                if spec.after then spec.after() end
            end,
        })
    end
    for _i, it in ipairs(customItems(surface)) do table.insert(items, it) end
    table.insert(items, { heading = _("Arrange") })
    table.insert(items, {
        text = T(_("Order of the %1…"), spec.things),
        description = surface == "home"
            and _("The chips sit at the right of the shelf, in this order from left to right.")
            or _("The tiles fill rows of four, in this order."),
        keep_menu_open = true,
        callback = function() arrange(surface) end,
    })
    if surface == "home" then
        table.insert(items, {
            text = _("Add a spacer"),
            description = _("Splits the bar: put it after the chips you want on the left (in the order above). Time on the left, the rest on the right, for example."),
            keep_menu_open = true,
            mandatory_func = function()
                local n = 0
                for _i, id in ipairs(Controls.ids("home")) do if Controls.isSpacer(id) then n = n + 1 end end
                return n > 0 and tostring(n) or nil
            end,
            callback = function(tm)
                Controls.addSpacer("home")
                refreshHome()
                if tm then tm:updateItems() end
                arrange("home")
            end,
        })
        table.insert(items, {
            text = _("Remove the spacers"),
            enabled_func = function()
                for _i, id in ipairs(Controls.ids("home")) do if Controls.isSpacer(id) then return true end end
                return false
            end,
            keep_menu_open = true,
            callback = function(tm)
                Controls.removeSpacers("home")
                refreshHome()
                if tm then tm:updateItems() end
            end,
        })
    end
    table.insert(items, {
        text = _("Long-press actions"),
        description = T(_("What holding each %1 does: its own default, or any KOReader action."), spec.thing),
        sub_item_table_func = function()
            local sub = {}
            for _i, c in ipairs(Controls.shown(surface)) do
                if not c.spacer then table.insert(sub, {
                    text = c.name,
                    page_title = T(_("Hold %1"), c.name),
                    mandatory_func = function() return Controls.holdName(surface, c) end,
                    sub_item_table_func = function() return holdPage(surface, c) end,
                }) end
            end
            if #sub == 0 then
                table.insert(sub, { text = T(_("No %1 chosen yet."), spec.things), enabled = false })
            end
            return sub
        end,
    })
    table.insert(items, {
        text = T(_("Reset the %1"), spec.things),
        description = T(_("Back to %1 with their own long-presses."), spec.defaults),
        keep_menu_open = true,
        callback = function(tm)
            Controls.reset(surface)
            if spec.after then spec.after() end
            if tm then tm:updateItems() end
        end,
    })
    return items
end

local function countText(surface)
    local n = 0
    for _i, c in ipairs(Controls.shown(surface)) do if not c.spacer then n = n + 1 end end
    return T(n == 1 and _("%1 control") or _("%1 controls"), n)
end

-- ---------------------------------------------------------------------------
-- The pages
-- ---------------------------------------------------------------------------

local HOME_SWIPE = {
    { key = "summary", text = _("Reading summary"),
      description = _("Today's reading, your streak and your recent books with the time spent on each.") },
    { key = "settings", text = _("Settings"), short = _("Settings"),
      description = _("This Settings app. (The ⚙ chip opens it too, if you keep it.)") },
    { key = "menu", text = _("KOReader's menu"), short = _("KOReader menu"),
      description = _("KOReader's original pull-down menu with its tabs of icons.") },
}

local READER_SWIPE = {
    { key = "qs", text = _("Quick Settings"),
      description = _("Wi-Fi, night mode and other tiles, brightness and warmth, and All settings.") },
    { key = "settings", text = _("Settings"),
      description = _("This Settings app.") },
    { key = "menu", text = _("KOReader's menu"), short = _("KOReader menu"),
      description = _("KOReader's original pull-down menu with its tabs of icons.") },
}

local ZONES = {
    { key = "narrow", text = _("A narrow column"), short = _("Narrow"),
      description = _("Only the middle third of the page opens the toolbar. Taps either side of it turn pages."),
      widget = function() return ZoneIcon:new{ zone = "narrow" } end },
    { key = "medium", text = _("The middle half"), short = _("Middle half"),
      description = _("The middle half of the page opens the toolbar; the outer quarters turn pages."),
      widget = function() return ZoneIcon:new{ zone = "medium" } end },
    { key = "wide", text = _("Most of the page"), short = _("Most"),
      description = _("Everything except a strip down each side opens the toolbar. Tap the strips to turn pages."),
      widget = function() return ZoneIcon:new{ zone = "wide" } end },
    { key = "off", text = _("Never"), short = _("Never"),
      description = _("Taps in the middle only turn pages, as in KOReader. The top and bottom edges can still open it (below)."),
      widget = function() return ZoneIcon:new{ zone = "off", edges = true } end },
}

local STATS_BUTTON = {
    { key = "panel", text = _("The stats panel"), short = _("Panel"),
      description = _("This chapter, the next one and the whole book, in a panel under the toolbar.") },
    { key = "koreader", text = _("KOReader's book statistics"), short = _("KOReader"),
      description = _("KOReader's full statistics screen for this book.") },
}

local function homeItems()
    return {
        toggle("home_status_bar", _("Show the status bar"),
            _("The row of chips across the top of the shelf. Off: the shelf gets that space back."), refreshHome),
        toggle("home_chip_labels", _("Names on the chips"),
            _("Show each chip's name next to its icon (LIGHT, WI-FI…). Off: icons only, like Kobo."), refreshHome,
            { checked_func = function() return Store.get("home_chip_labels") == true end,
              callback = function()
                  Store.set("home_chip_labels", not Store.get("home_chip_labels"))
                  refreshHome()
              end }),
        unpack(controlItems("home")),
    }
end

local function summaryItems()
    local items = {
        toggle("summary_stats", _("Reading figures"),
            _("Today, the last 7 days, your streak and the books you've read this year, from KOReader's reading statistics.")),
        toggle("summary_badges", _("Time on each cover"),
            _("A small badge on each recent book with the time you've spent reading it.")),
        { heading = _("Recent books") },
    }
    for _i, n in ipairs{ 3, 4, 5 } do
        table.insert(items, {
            text = T(_("%1 books"), n),
            description = n == 3 and _("Bigger covers.") or (n == 5 and _("Smaller covers.") or nil),
            radio = true,
            checked_func = function() return (Store.get("summary_books") or 4) == n end,
            callback = function() Store.set("summary_books", n) end,
        })
    end
    table.insert(items, { heading = _("Try it") })
    table.insert(items, {
        text = _("Open the reading summary"),
        description = _("Closes Settings and opens it, as swiping down on home does."),
        callback = function()
            UIManager:nextTick(function() require("bos_summary").show() end)
        end,
    })
    return items
end

local function qsItems()
    local items = controlItems("qs")
    table.insert(items, { heading = _("Light") })
    table.insert(items, toggle("qs_brightness", _("Brightness slider"),
        _("A brightness slider under the tiles.")))
    table.insert(items, toggle("qs_warmth", _("Warmth slider"),
        _("A warmth slider under the tiles, on devices with warm light."), nil,
        { enabled_func = function() return UI.Light.hasWarmth() end }))
    return items
end

local function toolbarItems()
    local function rezone() local tb = readerToolbar() if tb then tb:registerZones() end end
    return {
        { heading = _("Opening it") },
        {
            text = _("Tapping the middle of the page"),
            description = _("How much of the middle of the page opens the toolbar. The shaded part of each picture is where to tap."),
            mandatory_func = function() return choiceName("toolbar_zone", ZONES) end,
            sub_item_table_func = function() return radios("toolbar_zone", ZONES, rezone) end,
        },
        toggle("toolbar_edges", _("Tapping the top or bottom edge"),
            _("Tapping near the top or bottom of the page opens the toolbar too. Off: the top opens what swiping down opens, and the bottom opens the text sheet.")),
        toggle("custom_nav", _("ShelfTechUI's Contents, Notebook and Pages"),
            _("The toolbar's CONTENTS, NOTEBOOK and PAGES buttons open ShelfTechUI's own pages, and KOReader's skim bar becomes PAGES too. Off: KOReader's lists, page browser and skim bar.")),
        { heading = _("What it shows") },
        toggle("status_icons", _("Status line with icons"),
            _("The status line at the top (here, in Quick Settings, on the reading summary and in Settings): the time, then a sun with the brightness, a Wi-Fi icon, and a battery that fills with the charge next to its percentage. Off: Bookshelf's own status line.")),
        {
            text = _("The STATS button"),
            description = _("What STATS opens. Holding it always opens KOReader's statistics."),
            mandatory_func = function() return choiceName("stats_button", STATS_BUTTON) end,
            sub_item_table_func = function() return radios("stats_button", STATS_BUTTON) end,
        },
    }
end

--- Themes: the whole interface in one of six looks. Takes effect after a
--- restart (the theme is read once, at start), which it offers at once.
function Page.themeItems()
    local Theme = require("bos_theme")
    local items = { { heading = _("The whole interface in one look") } }
    for _i, id in ipairs(Theme.ORDER) do
        local th = Theme.THEMES[id]
        table.insert(items, {
            text = th.name,
            description = th.desc,
            radio = true,
            keep_menu_open = true,
            checked_func = function() return (Store.get("theme") or "retro") == id end,
            callback = function(tm)
                if (Store.get("theme") or "retro") == id then return end
                Store.set("theme", id)
                if tm and tm.updateItems then tm:updateItems() end
                if Theme.id() == id then return end -- back to the one in use
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = T(_("%1 is set. KOReader needs to restart to show it everywhere.\n\nRestart now?"), th.name),
                    ok_text = _("Restart"),
                    cancel_text = _("Later"),
                    ok_callback = function() UIManager:restartKOReader() end,
                })
            end,
        })
    end
    table.insert(items, { heading = _("Note") })
    table.insert(items, { text = _("Themes change everything ShelfTechUI restyles: its own screens, Bookshelf's home, Glimpse, the store, and KOReader's search, dictionary, text sheet, pop-ups, lists and menus. The book's own page keeps your reading font."), enabled = false })
    return items
end

--- The Settings app's sections, by what things are for:
---
---   HOME     the home screen and library (ShelfTechUI's, Bookshelf's, the file browser's)
---   READING  everything in a book (and KOReader's navigation and typesetting menus)
---   LOOK     the theme and how big, plus which KOReader screens are restyled
---   CONNECT  Transfer, the store, online picks
---   DEVICE   KOReader's own settings menu (light, screen, network, gestures…)
---   TOOLS    KOReader's tools and search menus
---   SYSTEM   history and favourites, help, about, reset, exit
---
--- A KOReader menu goes whole into its section under a heading, so nothing
--- is lost when KOReader or a plugin adds a row.
function Page.sections(plugin)
    local all = Page.items(plugin)
    local by = {}
    for _i, it in ipairs(all) do if it.text then by[it.text] = it end end
    -- what's placed already: a KOReader menu folded in later doesn't repeat it
    local placed = {}
    local function pick(out, names)
        for _i, n in ipairs(names) do
            if by[n] then table.insert(out, by[n]) placed[n] = true end
        end
    end
    -- KOReader's menus, by tab id
    local tabs, used = {}, {}
    for _i, tab in ipairs(plugin:tabs()) do
        local n = 0
        for _j, it in ipairs(tab) do if it.text ~= "KOMenu:separator" then n = n + 1 end end
        if n > 0 and tab.id then tabs[tab.id] = tab end
    end
    -- a KOReader row under a clearer name here (a copy: KOReader's own menu keeps its name)
    local function renamed(it, text)
        local c = {}
        for k, v in pairs(it) do c[k] = v end
        c.text, c.text_func = text, nil
        return c
    end
    local RENAME = {
        [_("Settings")] = { stui_home_fm = _("File browser settings"), stui_tools = _("Look-up settings") },
        [_("Device")] = { stui_device = _("Keyboard, time and more") },
    }
    local function fold(sec, id, heading)
        local tab = tabs[id]
        if not tab then return end
        used[id] = true
        sec.tabs = sec.tabs or {}
        table.insert(sec.tabs, tab)
        if heading then table.insert(sec.items, { heading = heading }) end
        for _i, it in ipairs(tab) do
            local t = it.text
            if not (t and placed[t]) then
                local r = t and RENAME[t] and RENAME[t][sec.rename_as or sec.id]
                -- Bookshelf's (icon-prefixed) Settings, beside the file browser's
                if id == "bookshelf_tab" and type(t) == "string" and t:match("%s%sSettings$") then
                    r = t:gsub("Settings$", _("Bookshelf settings"))
                end
                table.insert(sec.items, r and renamed(it, r) or it)
            end
        end
    end

    local home = { id = "stui_home", name = _("Home"), icon = "home", items = { { heading = _("Home layout") } } }
    -- one tap each: what home shows
    do
        local L = require("bos_layouts")
        for _i, id in ipairs(L.ORDER) do
            table.insert(home.items, {
                text = L.NAMES[id], radio = true,
                description = L.DESC[id] .. " " .. _("(To switch from home itself, add the Layout chip to the home bar: Status bar, below.)"),
                checked_func = function() return L.id() == id end,
                callback = function() L.set(id) end,
            })
        end
    end
    table.insert(home.items, { heading = _("Home screen") })
    pick(home.items, { _("Status bar"), _("Swipe down on home"), _("Reading summary"), _("Insights in the reading summary"),
        _("Edge swipes on home"), _("Start menu entries"), _("Settings in the start menu") })
    table.insert(home.items, { heading = _("Library") })
    pick(home.items, { _("Library"), _("For you") })
    fold(home, "bookshelf_tab", _("Bookshelf"))
    home.rename_as = "stui_home_fm"
    fold(home, "filemanager_settings", _("File browser"))
    fold(home, "filemanager")

    local reading = { id = "stui_reading", name = _("Reading"), icon = "book.opened", items = { { heading = _("In a book") } } }
    pick(reading.items, { _("Reading toolbar"), _("Quick Settings"), _("Swipe down in a book"), _("Handles on a selection"),
        _("ShelfTechUI text sheet"), _("Glimpse") })
    fold(reading, "navi", _("Navigation"))
    fold(reading, "typeset", _("Typesetting"))

    local look = { id = "stui_look", name = _("Look"), icon = "appbar.contrast", items = Page.themeItems() }
    -- (the note at the end of the themes moves under the fine-tuning)
    local note = table.remove(look.items)
    local note_heading = table.remove(look.items)
    table.insert(look.items, { heading = _("Fine-tuning") })
    pick(look.items, { _("Interface size"), _("KOReader screens") })
    table.insert(look.items, note_heading)
    table.insert(look.items, note)

    local Transfer = require("bos_transfer")
    local connect = { id = "stui_connect", name = _("Connect"), icon = "wifi.open.100", items = {
        { heading = _("Transfer") },
        {
            text = _("Transfer"),
            description = _("Send books to this device from a browser on the same Wi-Fi. Opening it turns it on and shows a QR code; its folder, password and timer are on the same page. Also a Quick Settings tile."),
            enabled_func = function() return Transfer.available() end,
            mandatory_func = function() return Transfer.isRunning() and _("On") or _("Off") end,
            callback = function() Transfer.show() end,
        },
        { heading = _("Store") },
        {
            text = _("Bookdrop store"),
            description = _("Browse and download books (and manga). Also the first shelf in FOR YOU on home."),
            enabled_func = function() return require("bos_online").bookdrop() ~= nil end,
            callback = function()
                local bd = require("bos_online").bookdrop()
                if bd then bd:showStoreHome() end
            end,
        },
    } }
    do
        -- online picks, lifted out of For you so they're one tap from here
        local fy = by[_("For you")]
        local sub = fy and fy.sub_item_table_func and fy.sub_item_table_func() or {}
        local lifted = { [_("Online picks")] = true, [_("Show online picks")] = true, [_("Want to read")] = true }
        for _i, it in ipairs(sub) do
            if lifted[it.text] then table.insert(connect.items, it) end
        end
        -- (and not again under Home → For you)
        if fy and fy.sub_item_table_func then
            local orig = fy.sub_item_table_func
            local home_fy = {}
            for k, v in pairs(fy) do home_fy[k] = v end
            home_fy.sub_item_table_func = function()
                local out = {}
                for _i, it in ipairs(orig() or {}) do
                    if not lifted[it.text] then table.insert(out, it) end
                end
                return out
            end
            for i, it in ipairs(home.items) do if it == fy then home.items[i] = home_fy end end
        end
    end

    placed[_("Transfer")], placed[_("Bookdrop store")] = true, true

    local device = { id = "stui_device", name = _("Device"), icon = "appbar.settings", items = {} }
    fold(device, "setting", _("This device"))

    local tools = { id = "stui_tools", name = _("Tools"), icon = "appbar.tools", items = {} }
    fold(tools, "tools", _("Tools"))
    fold(tools, "search", _("Search and look up"))

    local system = { id = "stui_system", name = _("System"), icon = "appbar.menu", items = {} }
    fold(system, "main", _("Shortcuts"))
    -- KOReader's Exit menu, opened out: each one tap, under its own heading
    for i, it in ipairs(system.items) do
        if it.text == _("Exit") and (it.sub_item_table or it.sub_item_table_func) then
            local sub = it.sub_item_table_func and it.sub_item_table_func() or it.sub_item_table or {}
            table.remove(system.items, i)
            table.insert(system.items, { heading = _("Power") })
            local said = {
                [_("Exit")] = _("Close KOReader."),
                [_("Restart KOReader")] = _("Close and open KOReader again."),
                [_("Sleep")] = _("Put the device to sleep."),
                [_("Power off")] = _("Turn the device off."),
                [_("Reboot the device")] = _("Restart the device."),
            }
            -- Exit last, as the end of the list
            local exit_item
            for _j, e in ipairs(sub) do
                if type(e) == "table" and e.text and e.text ~= "KOMenu:separator" then
                    e.description = e.description or said[e.text]
                    if e.text == _("Exit") then exit_item = e else table.insert(system.items, e) end
                end
            end
            if exit_item then table.insert(system.items, exit_item) end
            break
        end
    end
    -- KOReader's own "Update" (its OTA menu) sits in its main tab: it updates
    -- KOReader, not ShelfTechUI. Taken out of the shortcuts and put under
    -- Updates, after ShelfTechUI's, named for what it updates.
    local ko_update
    do
        local C_ = _.pgettext or function(_ctx, t) return _(t) end
        local names = { [C_("Application update | Menu", "Update")] = true, [_("Update")] = true }
        for i = #system.items, 1, -1 do
            local it = system.items[i]
            if not it.heading and names[it.text] then
                ko_update = table.remove(system.items, i)
                break
            end
        end
    end
    -- Updates at the top of System: ShelfTechUI's first, then KOReader's
    local upd = { { heading = _("Updates") } }
    for _i, it in ipairs(require("bos_update").settingsItems()) do table.insert(upd, it) end
    if ko_update then
        local k = renamed(ko_update, _("KOReader updates"))
        k.description = _("KOReader itself (not ShelfTechUI): KOReader's own updater, for a new KOReader version.")
        table.insert(upd, k)
    end
    for i = #upd, 1, -1 do table.insert(system.items, 1, upd[i]) end
    table.insert(system.items, { heading = _("ShelfTechUI") })
    pick(system.items, { _("About ShelfTechUI"), _("Reset all ShelfTechUI settings") })

    local sections = {}
    for _i, sec in ipairs{ home, reading, look, connect, device, tools, system } do
        local rows = 0
        for _j, it in ipairs(sec.items) do if not it.heading then rows = rows + 1 end end
        if rows > 0 then table.insert(sections, sec) end
    end
    -- any other KOReader menu (a plugin's own tab) keeps a section of its own
    for _i, tab in ipairs(plugin:tabs()) do
        if tab.id and tabs[tab.id] == tab and not used[tab.id] then
            table.insert(sections, { id = tostring(tab.id), name = plugin:tabName(tab), icon = tab.icon, items = tab })
        end
    end
    return sections
end

function Page.items()
    return {
        { heading = _("Home") },
        {
            text = _("Status bar"),
            description = _("The chips across the top of the shelf: which ones, their order, and what holding each does."),
            mandatory_func = function()
                return Store.get("home_status_bar") == false and _("Off") or countText("home")
            end,
            sub_item_table_func = homeItems,
            page_title = _("Home status bar"),
        },
        {
            text = _("Start menu entries"),
            description = _("Every entry in Bookshelf's start menu (≡), to move or remove. Holding an entry in the menu does the same."),
            enabled_func = function() return smModel() ~= nil end,
            sub_item_table_func = startMenuItems,
        },
        {
            text = _("Settings in the start menu"),
            description = _("The Settings app at the top of Bookshelf's start menu (≡). It's also an action (\"ShelfTechUI: Settings\") for any menu that takes actions: the start menu's own editor, gestures, the home status bar and Quick Settings."),
            enabled_func = function() return require("bos_startmenu").available() end,
            checked_func = function() return require("bos_startmenu").has() end,
            callback = function()
                local SM = require("bos_startmenu")
                SM.set(not SM.has())
            end,
        },
        {
            text = _("For you"),
            description = _("Recommendation shelves from your own library, the book page, and online picks from Open Library."),
            sub_item_table_func = function()
                return {
                    toggle("book_page", _("ShelfTechUI book page"),
                        _("Holding a book (or its details) opens the retro book page: stars, status, the description, genres, the series, Similar and More by the author, and ‹ › to the books beside it. Bookshelf's own book window is under its ⋯.")),
                    {
                        text = _("Online picks"),
                        description = _("Books you don't have yet: missing from your series, more by authors you finish, popular in your genres, as three shelves in FOR YOU on home. From Open Library, over Wi-Fi only, fetched at most once a day in the background, no account. Off by default."),
                        checked_func = function() return Store.get("online_picks") == true end,
                        callback = function()
                            require("bos_online").setEnabled(not (Store.get("online_picks") == true))
                            refreshHome()
                        end,
                    },
                    {
                        text = _("Show online picks"),
                        enabled_func = function() return Store.get("online_picks") == true end,
                        callback = function() require("bos_online").showPicks() end,
                    },
                    {
                        text = _("Want to read"),
                        callback = function() require("bos_online").showWant() end,
                    },
                    {
                        text = _("Add the For you shelf to home again"),
                        description = _("If you removed it: a FOR YOU shelf of shelves with Because you read, Up next in series, Pick back up, More by authors you finish, your top genres, Discover, the online picks (while they're on) and Want to read."),
                        keep_menu_open = true,
                        callback = function()
                            Store.set("foryou_seeded", nil)
                            Store.set("foryou_online_seeded", nil)
                            Store.set("foryou_store_seeded", nil)
                            require("bos_recs").seed()
                            require("bos_online").syncShelves()
                            require("bos_online").seedStore()
                            refreshHome()
                            UIManager:show(InfoMessage:new{ text = _("Added to home."), timeout = 2 })
                        end,
                    },
                }
            end,
        },
        {
            text = _("Library"),
            description = _("Every book on one page: search, sort, filter by status, A–Z, and select several to set their status or add them to a collection. Also in the start menu."),
            callback = function() require("bos_library").show() end,
        },
        toggle("home_edge_swipes", _("Edge swipes on home"),
            _("On Bookshelf's home: slide up or down along the left edge for brightness, the right edge for warmth, and swipe diagonally anywhere for a full refresh.")),
        {
            text = _("Interface size"),
            description = _("Everything bigger, from 100% to 120% (KOReader's screen DPI, scaled from your device's). KOReader restarts to apply it."),
            mandatory_func = function() return require("bos_device").currentSize() .. "%" end,
            sub_item_table_func = function()
                local Dev = require("bos_device")
                local sub = {}
                for _i, p in ipairs(Dev.SIZES) do
                    table.insert(sub, { text = p .. "%", checked_func = function() return Dev.currentSize() == p end,
                        callback = function() Dev.setSize(p) end })
                end
                return sub
            end,
        },
        {
            text = _("Swipe down on home"),
            description = _("What pulling down from the top of the shelf opens."),
            mandatory_func = function() return choiceName("home_swipe", HOME_SWIPE) end,
            sub_item_table_func = function() return radios("home_swipe", HOME_SWIPE) end,
        },
        toggle("summary_insights", _("Insights in the reading summary"),
            _("A second page in the reading summary (swipe it sideways): the last 26 weeks day by day, your yearly goal, when you'll finish, when you read, and your records.")),
        {
            text = _("Reading summary"),
            description = _("The panel swiping down on home opens: what it shows."),
            sub_item_table_func = summaryItems,
        },
        { heading = _("In a book") },
        {
            text = _("Quick Settings"),
            description = _("The panel you swipe down in a book: its tiles, their order, what holding each does, and the light sliders."),
            mandatory_func = function() return countText("qs") end,
            sub_item_table_func = qsItems,
        },
        {
            text = _("Swipe down in a book"),
            description = _("What pulling down from the top of a page opens."),
            mandatory_func = function() return choiceName("reader_swipe", READER_SWIPE) end,
            sub_item_table_func = function() return radios("reader_swipe", READER_SWIPE) end,
        },
        {
            text = _("Reading toolbar"),
            description = _("The bar you get by tapping the page: where to tap, and what it shows."),
            sub_item_table_func = toolbarItems,
        },
        toggle("highlight_handles", _("Handles on a selection"),
            _("When you've selected text, a handle at each end: drag one to take in more words, or fewer, before you highlight.")),
        {
            text = _("Glimpse"),
            description = _("Maps, family trees and other pictures in the book, from anywhere in it, without losing your place: GLIMPSE on the reading toolbar. Its settings: where it opens, the gallery, which images count."),
            enabled_func = function()
                local ReaderUI = package.loaded["apps/reader/readerui"]
                local ui = ReaderUI and ReaderUI.instance
                return ui and ui.glimpse and ui.glimpse._menuItems and true or false
            end,
            sub_item_table_func = function()
                local ReaderUI = package.loaded["apps/reader/readerui"]
                local ui = ReaderUI and ReaderUI.instance
                local ok, items = pcall(function() return ui.glimpse:_menuItems() end)
                return ok and items or { { text = _("Open a book to change Glimpse's settings."), enabled = false } }
            end,
        },
        toggle("text_sheet", _("ShelfTechUI text sheet"),
            _("Aa opens ShelfTechUI's sheet for fonts, size, spacing and margins. Off: KOReader's original bottom menu.")),
        {
            text = _("KOReader screens"),
            description = _("The dictionary, search, the skim bar, the highlight menu, notifications, pop-ups, KOReader's menu and the calendar, in your theme."),
            mandatory_func = function()
                local n = 0
                for _i, k in ipairs{ "dictionary", "skim", "search", "highlight", "toasts", "dialogs", "menu", "calendar" } do
                    if Store.get("skin_" .. k) ~= false then n = n + 1 end
                end
                return T(_("%1 of 8"), n)
            end,
            sub_item_table_func = function()
                return {
                    { heading = _("In your theme") },
                    toggle("skin_dictionary", _("The dictionary"),
                        _("A small window (at most half the screen) with a start menu of dictionaries and DICT · WIKI · HIGHLIGHT chips. Off: KOReader's own pop-up.")),
                    toggle("skin_skim", _("The skim bar"),
                        _("Skim document: chip buttons and Bookshelf's progress bar.")),
                    toggle("skin_search", _("Search"),
                        _("The search dialogs: chip buttons in a book; the file search as a themed window with themed results.")),
                    toggle("skin_highlight", _("The highlight menu"),
                        _("What you get after selecting text, and a highlight's edit menu: the text quoted, actions in segmented strips.")),
                    toggle("skin_toasts", _("Notifications"),
                        _("KOReader's short messages (like \"Bookmark added\") as a small themed window.")),
                    toggle("skin_dialogs", _("System pop-ups"),
                        _("KOReader's notices and confirmations as themed windows.")),
                    toggle("skin_menu", _("KOReader's main menu"),
                        _("Its tab bar in your theme, the open tab inverted.")),
                    toggle("skin_calendar", _("The reading calendar"),
                        _("A themed grid: today in black, books as bars.")),
                    { heading = _("Note") },
                    { text = _("Changes apply the next time each screen opens."), enabled = false },
                }
            end,
        },
        { heading = _("About") },
        {
            text = _("About ShelfTechUI"),
            description = T(_("Version %1, and who it's built on."), Page.VERSION),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("ShelfTechUI") .. " " .. Page.VERSION .. "\n\n"
                        .. _("A complete retro-tech interface for KOReader: home, reading toolbar, Quick Settings, text sheet, Contents, Notebook, Pages, pinned pages, six themes and a Settings app.") .. "\n\n"
                        .. _("Includes Bookshelf by AndyHazz, Glimpse by Erik Fanki and the Bookdrop store with RakuYomi (all AGPL-3.0), in ShelfTechUI's themes; Bookshelf's own settings are under its tab. The reading toolbar is based on the Kobo-style toolbar by Lina (nessnos, MIT). Inspired by Shortcuts Toolbar by xusoo and KoboUI by nessnos, and by ideas from Aleph (BookOrbit); no Aleph code is used."),
                })
            end,
        },
        {
            text = _("Reset all ShelfTechUI settings"),
            description = _("Every option on these pages back to how it came."),
            keep_menu_open = true,
            callback = function(tm)
                UIManager:show(ConfirmBox:new{
                    text = _("Reset all ShelfTechUI settings?"),
                    ok_text = _("Reset"),
                    ok_callback = function()
                        G_reader_settings:delSetting("bookshelfos")
                        refreshHome()
                        local tb = readerToolbar()
                        if tb then tb:registerZones() end
                        if tm then tm:updateItems() end
                    end,
                })
            end,
        },
    }
end

return Page
