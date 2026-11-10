--[[
The controls: one catalogue for the two places you put them.

  * "home": the chips across the top of Bookshelf home (Kobo-style). Light and
    Wi-Fi open a small menu under the chip; the others act straight away.
  * "qs":   the tiles of Quick Settings, the panel you swipe down in a book
    (Kindle-style). A tile toggles or acts.

Each place has its own list and order (Settings → ShelfTechUI), and each
control in each place its own long-press: what it does by default, or any
KOReader action you pick.
--]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Store = require("bos_settings_store")
local UI = require("bos_ui")

local function event(name, ...)
    local args = { ... }
    return function() UIManager:broadcastEvent(Event:new(name, unpack(args))) end
end

local function readerUI()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local ui = ReaderUI and ReaderUI.instance
    if ui and ui.document then return ui end
end

local function wifiOn()
    local ok, on = pcall(function() return require("ui/network/manager"):isWifiOn() end)
    return ok and on
end

local function networks()
    require("bos_ui").chooseNetwork()
end

local function batteryLevel()
    local ok, lvl = pcall(function() return Device:getPowerDevice():getCapacity() end)
    return ok and type(lvl) == "number" and lvl or nil
end

local function clock()
    return require("datetime").secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
end

--[[ A control:
  id, name, glyph
  available()              shown at all on this device / here
  home = { menu = "light" | tap = fn(ctx), text = fn() }   (nil: not for home)
  qs   = { tap = fn(ctx) }                                 (nil: not for Quick Settings)
  active()                 filled black while true (a toggle that's on)
  hold = { home = fn(ctx), qs = fn(ctx), name = "what it does" }   the default long-press
  says = { home = "…", qs = "…" }   what a tap does, for the settings page
  ctx: { anchor = Geom (home), close = fn(then) (closes the panel / nothing on home) }
]]
local CATALOGUE = {
    {
        id = "light", name = _("Light"), glyph = UI.GLYPH.sun,
        available = function() return Device:hasFrontlight() end,
        active = function()
            local ok, on = pcall(function() return Device:getPowerDevice():isFrontlightOn() end)
            return ok and on
        end,
        home = { menu = "light" },
        qs = { tap = event("ToggleFrontlight") },
        hold = { home = event("ToggleFrontlight"), qs = event("ShowFlDialog"),
                 name_home = _("light on/off"), name_qs = _("KOReader's light dialog") },
        says = { home = _("Brightness, warmth and night mode, in a menu under the chip."),
                 qs = _("Turns the light on or off.") },
        no_fill_home = true, -- on home the chip opens a menu: no on/off fill
    },
    {
        id = "wifi", name = _("Wi-Fi"), glyph = UI.GLYPH.wifi,
        available = function() return Device:hasWifiToggle() end,
        active = wifiOn, slow = true,
        home = { menu = "wifi" },
        qs = { tap = event("ToggleWifi"),
               sub = function() return require("bos_status").wifiLine() end },
        hold = { home = networks, qs = networks, name_home = _("choose a network"), name_qs = _("choose a network") },
        says = { home = _("On/off, the network you're on, and other networks, in a menu under the chip."),
                 qs = _("Turns Wi-Fi on or off.") },
    },
    {
        id = "night", name = _("Night"), glyph = UI.GLYPH.moon,
        available = function() return true end,
        active = function() return G_reader_settings:isTrue("night_mode") end,
        home = { tap = event("ToggleNightMode") },
        qs = { tap = event("ToggleNightMode"), closes = true },
        says = { home = _("Turns night mode (white on black) on or off."),
                 qs = _("Turns night mode (white on black) on or off.") },
    },
    {
        id = "rotate", name = _("Rotate"), glyph = UI.GLYPH.rotate,
        available = function() return true end,
        home = { tap = event("SwapRotation") },
        qs = { tap = event("SwapRotation"), closes = true },
        hold = { home = event("IterateRotation"), qs = event("IterateRotation"),
                 name_home = _("rotate by 90°"), name_qs = _("rotate by 90°") },
        says = { home = _("Switches between portrait and landscape."),
                 qs = _("Switches between portrait and landscape.") },
    },
    {
        id = "refresh", name = _("Refresh"), glyph = UI.GLYPH.refresh,
        available = function() return true end,
        home = { tap = event("FullRefresh") },
        qs = { tap = event("FullRefresh"), closes = true },
        says = { home = _("A full e-ink refresh, to clear ghosting."),
                 qs = _("A full e-ink refresh, to clear ghosting.") },
    },
    {
        id = "bookmark", name = _("Bookmark"), glyph = UI.GLYPH.bookmark,
        available = function() return readerUI() ~= nil end,
        active = function()
            local ui = readerUI()
            return ui and ui.bookmark and ui.bookmark:isPageBookmarked() or false
        end,
        qs = { tap = event("ToggleBookmark") },
        hold = { qs = event("ShowBookmark"), name_qs = _("your bookmarks") },
        says = { qs = _("Bookmarks this page, or removes its bookmark.") },
    },
    {
        id = "library", name = _("Library"), glyph = UI.GLYPH.book,
        available = function() return readerUI() ~= nil end,
        qs = { tap = function()
            local ui = readerUI()
            if ui then require("bos_shelf").back(ui) end
        end, closes = true },
        says = { qs = _("Back to Bookshelf (the book stays open underneath).") },
    },
    {
        id = "search", name = _("Search"), glyph = UI.GLYPH.search,
        available = function() return true end,
        home = { tap = event("ShowFileSearch") },
        qs = { tap = event("ShowFulltextSearchInput"), closes = true },
        says = { home = _("Searches your books by file name."),
                 qs = _("Searches the text of this book.") },
    },
    {
        id = "dictionary", name = _("Dictionary"), glyph = UI.GLYPH.dictionary,
        available = function() return true end,
        home = { tap = event("ShowDictionaryLookup") },
        qs = { tap = event("ShowDictionaryLookup"), closes = true },
        says = { home = _("Look a word up in your dictionaries."),
                 qs = _("Look a word up in your dictionaries.") },
    },
    {
        id = "stats", name = _("Stats"), glyph = UI.GLYPH.chart,
        available = function() return true end,
        home = { tap = event("ShowReaderProgress") },
        qs = { tap = event("ShowBookStats"), closes = true },
        hold = { home = event("ShowCalendarView"), qs = event("ShowCalendarView"),
                 name_home = _("reading calendar"), name_qs = _("reading calendar") },
        says = { home = _("Your reading statistics."), qs = _("This book's reading statistics.") },
    },
    {
        id = "calendar", name = _("Calendar"), glyph = UI.GLYPH.calendar,
        available = function() return true end,
        home = { tap = event("ShowCalendarView") },
        qs = { tap = event("ShowCalendarView"), closes = true },
        says = { home = _("The reading calendar: what you read, day by day."),
                 qs = _("The reading calendar: what you read, day by day.") },
    },
    {
        id = "battery", name = _("Battery"), glyph = UI.GLYPH.battery,
        available = function() return Device:hasBattery() end,
        home = { tap = event("ShowBatteryStatistics"),
                 text = function() local l = batteryLevel() return l and (l .. "%") end },
        says = { home = _("Shows the charge; tap for battery statistics.") },
    },
    {
        id = "time", name = _("Time"), glyph = nil,
        available = function() return true end,
        home = { tap = event("ShowCalendarView"), text = clock },
        says = { home = _("Shows the time; tap for the reading calendar.") },
    },
    {
        id = "screenshot", name = _("Screenshot"), glyph = UI.GLYPH.camera,
        available = function() return true end,
        home = { tap = event("Screenshot") },
        qs = { tap = event("Screenshot"), closes = true },
        says = { home = _("Takes a screenshot."), qs = _("Takes a screenshot (after the panel closes).") },
    },
    {
        id = "sleep", name = _("Sleep"), glyph = UI.GLYPH.power,
        available = function() return Device:canSuspend() end,
        home = { tap = event("RequestSuspend") },
        qs = { tap = event("RequestSuspend"), closes = true },
        says = { home = _("Puts the device to sleep."), qs = _("Puts the device to sleep.") },
    },
    {
        -- X-Ray (xray.koplugin), when it's installed: its first action, or a
        -- list of them
        id = "xray", name = _("X-Ray"), glyph = UI.GLYPH.info,
        available = function() return #require("bos_daily").xrayActions() > 0 end,
        qs = { tap = function()
            local acts = require("bos_daily").xrayActions()
            if #acts == 1 then return require("bos_daily").runAction(acts[1].id) end
            local items = {}
            for _i, a in ipairs(acts) do
                table.insert(items, { text = a.title, callback = function() require("bos_daily").runAction(a.id) end })
            end
            require("bos_ui").openList(items, nil)
        end, closes = true },
        says = { qs = _("X-Ray for this book (the X-Ray plugin): characters, places, terms.") },
    },
    {
        -- Transfer (bos_transfer): a tap opens its page, which turns it on
        -- and shows the QR code; a hold turns it on or off without the page
        id = "transfer", name = _("Transfer"), glyph = UI.GLYPH.upload,
        available = function() return require("bos_transfer").available() end,
        active = function() return require("bos_transfer").isRunning() end,
        home = { tap = function() require("bos_transfer").show() end },
        qs = { tap = function() require("bos_transfer").show() end, closes = true },
        hold = { home = function() require("bos_transfer").toggle() end,
                 qs = function() require("bos_transfer").toggle() end, name = _("On or off, without its page") },
        says = { home = _("Send books to this device from a browser on the same Wi-Fi: opens Transfer and turns it on."),
                 qs = _("Send books to this device from a browser on the same Wi-Fi: opens Transfer and turns it on.") },
    },
    {
        -- the home layout (bos_layouts): Shelf, Read or Dash
        id = "layout", name = _("Layout"), glyph = UI.GLYPH.grid_large,
        available = function() return true end,
        home = { tap = function(ctx) require("bos_layouts").choose(ctx and ctx.anchor) end },
        hold = { home = function() require("bos_layouts").cycle() end, name_home = _("the next layout") },
        says = { home = _("Home as Shelf, Read or Dash.") },
    },
    {
        id = "settings", name = _("Settings"), glyph = UI.GLYPH.cog,
        available = function() return true end,
        home = { tap = function() require("bos_settings").open() end },
        qs = { tap = function() require("bos_settings").open() end, closes = true },
        says = { home = _("Opens the Settings app."), qs = _("Opens the Settings app.") },
    },
}

local Controls = {}
Controls.CATALOGUE = CATALOGUE

local BY_ID = {}
for _i, c in ipairs(CATALOGUE) do BY_ID[c.id] = c end
Controls.BY_ID = BY_ID

-- ---- your own shortcuts ------------------------------------------------------
--[[ Store "custom_controls": a list of
  { id = "custom_<n>", kind = "plugin" | "action", name = (optional),
    plugin = <KOReader menu key>,        kind "plugin": that plugin's menu entry
    action = { <Dispatcher action> },    kind "action": any KOReader action
    glyph = <UI.GLYPH key> }
Both surfaces share the list; each shows a shortcut only once it's added there. ]]

Controls.GLYPHS = { "puzzle", "plug", "star", "heart", "bolt", "flag", "cloud", "globe", "folder", "files",
    "book", "bookmark", "tags", "download", "upload", "rss", "music", "terminal", "key", "bell", "pencil",
    "sliders", "grid", "list", "chart", "clock", "calendar", "info", "home", "power" }

function Controls.customs()
    local raw = Store.raw()
    if type(raw.custom_controls) ~= "table" then raw.custom_controls = {} end
    return raw.custom_controls
end

function Controls.customDef(id)
    for _i, d in ipairs(Controls.customs()) do if d.id == id then return d end end
end

local function topSettings()
    local ok, Settings = pcall(require, "bos_settings")
    return ok and Settings.top and Settings.top() or nil
end

local function menuText(item)
    local ok, t = pcall(function() return item.text_func and item.text_func() or item.text end)
    t = ok and t or nil
    -- "FilebrowserPlus (Long press for settings)" -> "FilebrowserPlus"
    if type(t) == "string" then
        t = t:gsub("%s*%b()%s*$", ""):gsub("…$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    end
    return t
end
Controls.menuText = menuText

local function menuOf(s)
    local menu = s and s.ui and s.ui.menu
    if menu and menu.tab_item_table == nil then pcall(menu.setUpdateItemTable, menu) end
    return menu
end

--- A plugin's own menu entries, fresh from its addToMainMenu (KOReader's menu
--- sorter consumes the live table, so this is how to reach one by key).
local function probe(widget)
    local t = {}
    pcall(widget.addToMainMenu, widget, t)
    return t
end

local function isPlugin(widget)
    return type(widget) == "table" and type(widget.addToMainMenu) == "function"
        and widget.path ~= nil and widget.name ~= "shelftechui"
end

--- Every plugin's menu entries in the UI on screen, by key: asked of each
--- plugin once (per UI, and again only when a plugin comes or goes), never
--- by building KOReader's whole menu. The bar draws from this.
local entries = setmetatable({}, { __mode = "k" }) -- menu -> { n = #plugins, items = { key = item }, owners = }

local function pluginTable(menu)
    local reg = menu.registered_widgets or {}
    local pc = entries[menu]
    if pc and pc.n == #reg then return pc end
    pc = { n = #reg, items = {}, owners = {} }
    for _i, widget in ipairs(reg) do
        if isPlugin(widget) then
            for key, item in pairs(probe(widget)) do
                if type(item) == "table" and pc.items[key] == nil then
                    pc.items[key] = item
                    pc.owners[key] = widget
                end
            end
        end
    end
    entries[menu] = pc
    return pc
end

--- A plugin's menu entry `key`, cheaply (no menu built): item, its plugin.
function Controls.pluginItem(key)
    local s = topSettings()
    local menu = s and s.ui and s.ui.menu
    if not menu then return end
    local pc = pluginTable(menu)
    return pc.items[key], pc.owners[key]
end

--- Find a plugin's menu entry `key` in the UI on screen: item, tab, path,
--- settings app. (tab/path: where it sits in KOReader's menu, when found.)
--- For a tap: this builds KOReader's menu if it isn't built yet.
local cache = setmetatable({}, { __mode = "k" }) -- menu -> { tabs = , [key] = { item, tab, path } }

function Controls.findMenuItem(key)
    local s = topSettings()
    local menu = menuOf(s)
    if not menu then return end
    local mc = cache[menu]
    if not mc or mc.tabs ~= menu.tab_item_table then
        mc = { tabs = menu.tab_item_table }
        cache[menu] = mc
    end
    local hit = mc[key]
    if hit then
        if hit.none then return end
        return hit.item, hit.tab, hit.path, s
    end
    local item, tab, path = Controls._locate(menu, key)
    mc[key] = item and { item = item, tab = tab, path = path } or { none = true }
    return item, tab, path, s
end

function Controls._locate(menu, key)
    local item = pluginTable(menu).items[key]
    if not item then return end
    -- its place in the menu, by its text
    local want = menuText(item)
    local found_tab, found_path, live
    local function walk(items, path, depth)
        if found_path or depth > 6 or type(items) ~= "table" then return end
        for i, it in ipairs(items) do
            if found_path then return end
            local p = { unpack(path) }
            table.insert(p, i)
            if want and menuText(it) == want then found_path, live = p, it return end
            if type(it.sub_item_table) == "table" then walk(it.sub_item_table, p, depth + 1) end
        end
    end
    for _i, tab in ipairs(menu.tab_item_table or {}) do
        walk(tab, {}, 0)
        if found_path then found_tab = tab break end
    end
    return live or item, found_tab, found_path
end

local function actionName(action)
    if type(action) ~= "table" or next(action) == nil then return nil end
    local ok, name = pcall(Dispatcher.menuTextFunc, Dispatcher, action)
    if ok and name and name ~= "" and name ~= _("Nothing") then return name end
end
Controls.actionName = actionName

--- The shortcut's name, as shown on its chip / tile.
function Controls.customName(d)
    if d.name and d.name ~= "" then return d.name end
    if d.kind == "plugin" then return d.plugin_name or d.plugin or _("Plugin") end
    return actionName(d.action) or _("New shortcut")
end

local function noop() end

--- A stand-in for KOReader's TouchMenu, for callbacks that talk to the menu
--- they were tapped in: anything they call that it doesn't have is a no-op,
--- never an error that stops the plugin.
local function menuStandIn(fields)
    return setmetatable(fields, { __index = function(_t, k)
        if k == "item_table" or k == "item_table_stack" then return {} end
        return noop
    end })
end

--- Open the entry in the Settings app, at its place, and run `then_fn(screen)`.
local function inApp(tab, path, s, then_fn)
    if not s then return false end
    UIManager:nextTick(function()
        if tab then s:openAt(tab, path) else s:showHome() end
        if s.screen and then_fn then then_fn(s.screen) end
    end)
    return true
end

local function notHere(d)
    UIManager:show(require("ui/widget/infomessage"):new{
        text = T(_("%1 isn't available here."), Controls.customName(d)), timeout = 3 })
end

--- Tap a plugin's menu entry: its sub-page in the Settings app, or its action.
--- If the action fails, its place in the Settings app opens instead, so a tap
--- always does something.
local function pluginTap(d)
    local item, tab, path, s = Controls.findMenuItem(d.plugin)
    if not item then return notHere(d) end
    local enabled = true
    pcall(function() if item.enabled_func then enabled = item.enabled_func() ~= false
        elseif item.enabled == false then enabled = false end end)
    local sub = item.sub_item_table_func or item.sub_item_table
    if not enabled or sub or item.tap_input or item.tap_input_func then
        inApp(tab, path, s, function(screen) screen:activate(item) end)
        return
    end
    local cb = item.callback_func and item.callback_func() or item.callback
    if not cb then return inApp(tab, path, s) end
    local tm = menuStandIn{
        onMenuSelect = function(_, it) inApp(tab, path, s, function(screen) screen:activate(it) end) return true end,
        onMenuHold = function(_, it) inApp(tab, path, s, function(screen) screen:hold(it) end) return true end,
    }
    local ok, err = pcall(cb, tm)
    if not ok then
        logger.warn("ShelfTechUI: shortcut", d.plugin, "failed, opening its menu entry:", err)
        inApp(tab, path, s)
    end
end

--- Hold a plugin's entry: what holding it in the menu does (often its
--- settings), else its place in the Settings app.
local function pluginHold(d)
    local item, tab, path, s = Controls.findMenuItem(d.plugin)
    if not item then return notHere(d) end
    if item.hold_callback or item.hold_callback_func or item.hold_input or item.hold_input_func then
        inApp(tab, path, s, function(screen) screen:hold(item) end)
    else
        inApp(tab, path, s)
    end
end

local function buildCustom(d)
    local function tap()
        if d.kind == "plugin" then return pluginTap(d) end
        if type(d.action) == "table" and next(d.action) ~= nil then Dispatcher:execute(d.action) end
    end
    local c = {
        id = d.id, custom = d,
        name = Controls.customName(d),
        glyph = UI.GLYPH[d.glyph or "puzzle"] or UI.GLYPH.puzzle,
        available = function()
            if d.kind ~= "plugin" then return true end
            return Controls.pluginItem(d.plugin) ~= nil
        end,
        home = { tap = tap },
        qs = { tap = tap, closes = true },
        slow = true,
    }
    if d.kind == "plugin" then
        c.active = function()
            local item = Controls.pluginItem(d.plugin)
            return item and item.checked_func and item.checked_func() and true or false
        end
        c.hold = { home = function() pluginHold(d) end, qs = function() pluginHold(d) end,
                   name_home = _("its settings"), name_qs = _("its settings") }
        local what = T(_("Runs %1, as its entry in KOReader's menu does."), Controls.customName(d))
        c.says = { home = what, qs = what }
    else
        local what = T(_("Runs: %1."), actionName(d.action) or _("nothing yet"))
        c.says = { home = what, qs = what }
    end
    return c
end

--- A spacer (home only): splits the bar, so chips can sit on the left too.
local function spacer(id)
    return { id = id, name = _("Spacer"), spacer = true, home = {},
             available = function() return true end,
             says = { home = _("Empty room that pushes the chips after it to the right.") } }
end

function Controls.isSpacer(id) return type(id) == "string" and id:match("^spacer_%d+$") ~= nil end

function Controls.addSpacer(surface)
    local ids, n = Controls.ids(surface), 1
    for _i, x in ipairs(ids) do
        local k = tonumber(tostring(x):match("^spacer_(%d+)$"))
        if k and k >= n then n = k + 1 end
    end
    local out = {}
    for _i, x in ipairs(ids) do table.insert(out, x) end
    table.insert(out, 1, "spacer_" .. n) -- first: the chips stay on the right
    Controls.setIds(surface, out)
end

function Controls.removeSpacers(surface)
    local out = {}
    for _i, x in ipairs(Controls.ids(surface)) do
        if not Controls.isSpacer(x) then table.insert(out, x) end
    end
    Controls.setIds(surface, out)
end

function Controls.get(id)
    if BY_ID[id] then return BY_ID[id] end
    if Controls.isSpacer(id) then return spacer(id) end
    local d = Controls.customDef(id)
    return d and buildCustom(d) or nil
end

function Controls.newCustom(fields)
    local list = Controls.customs()
    local n = 1
    for _i, d in ipairs(list) do
        local k = tonumber((d.id or ""):match("^custom_(%d+)$"))
        if k and k >= n then n = k + 1 end
    end
    local d = { id = "custom_" .. n, glyph = "puzzle" }
    for k, v in pairs(fields or {}) do d[k] = v end
    table.insert(list, d)
    Store.save()
    return d
end

function Controls.removeCustom(id)
    local list = Controls.customs()
    for i = #list, 1, -1 do if list[i].id == id then table.remove(list, i) end end
    for _i, surface in ipairs{ "home", "qs" } do
        local ids, out = Controls.ids(surface), {}
        for _j, x in ipairs(ids) do if x ~= id then table.insert(out, x) end end
        Store.set(surface .. "_controls", out)
        Controls.holds(surface)[id] = nil
    end
    Store.save()
end

--- Plugins with an entry in KOReader's menu here: { { key, name, plugin } }, by name.
function Controls.pluginEntries()
    local s = topSettings()
    local menu = s and s.ui and s.ui.menu
    if not menu then return {} end
    local pc = pluginTable(menu)
    local list = {}
    for key, item in pairs(pc.items) do
        local name = menuText(item)
        if name and name ~= "" then
            local widget = pc.owners[key]
            local pname = widget.fullname or (widget.name or ""):gsub("^filemanager", ""):gsub("^reader", "")
            table.insert(list, { key = key, name = name, plugin = pname })
        end
    end
    table.sort(list, function(x, y) return x.name:lower() < y.name:lower() end)
    return list
end


Controls.DEFAULTS = {
    home = { "light", "wifi", "settings" },
    qs = { "wifi", "night", "rotate", "refresh" },
}

local function listKey(surface) return surface .. "_controls" end
local function holdKey(surface) return surface .. "_holds" end

--- Every control that can go in `surface`, in catalogue order.
function Controls.candidates(surface)
    local list = {}
    for _i, c in ipairs(CATALOGUE) do
        if c[surface] then table.insert(list, c) end
    end
    for _i, d in ipairs(Controls.customs()) do table.insert(list, buildCustom(d)) end
    return list
end

--- The ids chosen for `surface`, in order (saved, or the defaults).
function Controls.ids(surface)
    local ids = Store.get(listKey(surface))
    if type(ids) ~= "table" then
        ids = {}
        for _i, id in ipairs(Controls.DEFAULTS[surface]) do table.insert(ids, id) end
    end
    return ids
end

function Controls.setIds(surface, ids) Store.set(listKey(surface), ids) end

function Controls.isOn(surface, id)
    for _i, x in ipairs(Controls.ids(surface)) do if x == id then return true end end
    return false
end

function Controls.toggle(surface, id)
    local ids, out, found = Controls.ids(surface), {}, false
    for _i, x in ipairs(ids) do
        if x == id then found = true else table.insert(out, x) end
    end
    if not found then
        -- new ones go before ⚙ when it's last, so Settings stays at the end
        if out[#out] == "settings" and id ~= "settings" then
            table.insert(out, #out, id)
        else
            table.insert(out, id)
        end
    end
    Controls.setIds(surface, out)
end

--- The controls to show in `surface` right now (chosen, known, available here).
function Controls.shown(surface)
    local list = {}
    for _i, id in ipairs(Controls.ids(surface)) do
        local c = Controls.get(id)
        if c and c[surface] then
            local ok, avail = pcall(c.available)
            if ok and avail then table.insert(list, c) end
        end
    end
    return list
end

function Controls.reset(surface)
    Store.set(listKey(surface), nil)
    Store.set(holdKey(surface), nil)
end

-- ---- taps and long-presses -------------------------------------------------

--- The long-press table for `surface` (id -> KOReader action), live.
function Controls.holds(surface)
    local raw = Store.raw()
    local key = holdKey(surface)
    if type(raw[key]) ~= "table" then raw[key] = {} end
    return raw[key]
end

local function hasAction(t)
    if type(t) ~= "table" then return false end
    for k, _v in pairs(t) do if k ~= "settings" then return true end end
    return false
end

--- What a long-press on `c` in `surface` does, in words.
function Controls.holdName(surface, c)
    local custom = Controls.holds(surface)[c.id]
    if hasAction(custom) then
        local ok, name = pcall(Dispatcher.menuTextFunc, Dispatcher, custom)
        return ok and name or _("a KOReader action")
    end
    local h = c.hold
    local name = h and h["name_" .. surface]
    return name or _("nothing")
end

--- Tap. ctx.close(fn) closes the panel and then runs fn (Quick Settings).
function Controls.tap(surface, c, ctx)
    local spec = c[surface]
    local run = spec.tap
    if not run then return end
    local function go()
        local ok, err = pcall(run, ctx)
        if not ok then logger.warn("ShelfTechUI: control", c.id, "failed:", err) end
    end
    if spec.closes and ctx and ctx.close then ctx.close(go) else go() end
end

--- Long-press: the action picked in settings, else the control's own.
--- Returns false when there's nothing to do.
function Controls.hold(surface, c, ctx)
    local custom = Controls.holds(surface)[c.id]
    local run
    if hasAction(custom) then
        run = function() Dispatcher:execute(custom) end
    else
        run = c.hold and c.hold[surface]
    end
    if not run then return false end
    local function go()
        local ok, err = pcall(run, ctx)
        if not ok then logger.warn("ShelfTechUI: long-press", c.id, "failed:", err) end
    end
    if ctx and ctx.close then ctx.close(go) else go() end
    return true
end

return Controls
