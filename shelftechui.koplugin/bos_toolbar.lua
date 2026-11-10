--[[
The reading toolbar (reader only).

Tap the middle, the top or the bottom of the page to show it over the page:
  * on top: Home and Search keys, the book card (cover, chapter, progress,
    when you'll finish, a bookmark key) and the books you're also reading;
  * at the bottom: a track with chapter ticks to skim with ("Return to page"
    appears after skimming), CONTENTS · NOTEBOOK · PAGES, and
    GLIMPSE · PIN · STATS, each with a figure (bos_rowdata).

Based on Lina's Kobo-style toolbar (MIT).
--]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Store = require("bos_settings_store")

local ZONE_ID = "bos_toolbar_tap"
local TOP_TAP_ID = "bos_toolbar_top_tap"
local TOP_EXT_TAP_ID = "bos_toolbar_top_ext_tap"
local BOTTOM_TAP_ID = "bos_toolbar_bottom_tap"
local BOTTOM_EXT_TAP_ID = "bos_toolbar_bottom_ext_tap"

-- Zones that keep priority over ours: links, existing highlights, the corner
-- taps set up in Taps and gestures (e.g. the bookmark corner), and Bookshelf's
-- in-reader launchers (≡ start menu, ⊞ micro-modules).
local ZONES_BEFORE_US = {
    "tap_link", "readerhighlight_tap", "readerhighlight_tap_select_mode",
    "bookshelf_launcher_tap", "bookshelf_grid_tap",
}
local EDGE_ZONES_BEFORE_US = {
    "tap_link", "readerhighlight_tap", "readerhighlight_tap_select_mode",
    "tap_top_left_corner", "tap_top_right_corner", "tap_left_bottom_corner", "tap_right_bottom_corner",
    "bookshelf_launcher_tap", "bookshelf_grid_tap",
}
local OUR_ZONES = {
    [ZONE_ID] = ZONES_BEFORE_US,
    [TOP_TAP_ID] = EDGE_ZONES_BEFORE_US,
    [TOP_EXT_TAP_ID] = EDGE_ZONES_BEFORE_US,
    [BOTTOM_TAP_ID] = EDGE_ZONES_BEFORE_US,
    [BOTTOM_EXT_TAP_ID] = EDGE_ZONES_BEFORE_US,
}

-- The middle column of the page (screen ratios). Left and right of it turn pages.
local ZONES = {
    narrow = { x = 1/3, y = 1/8, w = 1/3, h = 3/4 },
    medium = { x = 1/4, y = 1/8, w = 1/2, h = 3/4 },
    wide   = { x = 1/8, y = 1/8, w = 3/4, h = 3/4 },
}

-- The bottom row, in order. Fixed: every cell has one job, and under its name
-- a figure of its own (bos_rowdata).
-- (no BOOK: the book card opens the book page; no LIGHT or TEXT: the swipes
-- have them; no MORE: bookmarks are on the card and in NOTEBOOK)
local BUTTONS = { { id = "glimpse" }, { id = "pin" }, { id = "stats" } }

local Toolbar = {}
Toolbar.__index = Toolbar

--- The widget reads its preferences through this: the stats view it
--- remembers and what STATS opens.
local function settingsProxy()
    local map = { stats_view = "stats_view", stats_button = "stats_button" }
    return setmetatable({}, {
        __index = function(_t, k)
            if map[k] then return Store.get(map[k]) end
            return nil
        end,
        __newindex = function(_t, k, v)
            if map[k] then Store.set(map[k], v) end
        end,
    })
end

function Toolbar.new(ui)
    local self = setmetatable({ ui = ui, settings = settingsProxy() }, Toolbar)
    -- the MORE menu is gone (1.1.4): its saved actions with it
    local raw = Store.raw()
    if raw.more_actions ~= nil or raw.more_book_info_migrated ~= nil or raw.more_go_to_migrated ~= nil then
        raw.more_actions, raw.more_book_info_migrated, raw.more_go_to_migrated = nil, nil, nil
        Store.save()
    end
    if Device:isTouchDevice() then
        self:hookZoneRegistration()
        self:registerZones()
    end
    self:hookPageAnimation()
    return self
end

function Toolbar:saveSettings() Store.save() end

function Toolbar:getButtons()
    local list = {}
    for _i, b in ipairs(BUTTONS) do
        -- GLIMPSE when Glimpse can read this book (not PDFs or comics)
        if b.id ~= "glimpse" or require("bos_rowdata").glimpseWorks(self.ui) then table.insert(list, b) end
    end
    return list
end

--- 📖: back to Bookshelf (it parks the book: coming back is instant).
function Toolbar:goBack()
    local ui = self.ui
    local ok, err = pcall(require("bos_shelf").back, ui)
    if not ok then
        logger.warn("ShelfTechUI: back button failed, using the file browser:", err)
        ui:handleEvent(Event:new("Home"))
    end
end

-- ------------------------------------------------------------ touch zones

function Toolbar:registerZones()
    local zone = Store.get("toolbar_zone")
    local z = ZONES[zone] or ZONES.medium
    local function sz(r) return { ratio_x = r.x, ratio_y = r.y, ratio_w = r.w, ratio_h = r.h } end
    local function open(edge)
        return function()
            -- the middle (unless "Off"); the top and bottom edges (unless turned off)
            if not edge and Store.get("toolbar_zone") == "off" then return false end
            if edge and Store.get("toolbar_edges") == false then return false end
            self:showToolbar()
            return true
        end
    end
    local menu_zone = G_defaults:readSetting("DTAP_ZONE_MENU")
    local menu_ext = G_defaults:readSetting("DTAP_ZONE_MENU_EXT")
    local cfg_zone = G_defaults:readSetting("DTAP_ZONE_CONFIG")
    local cfg_ext = G_defaults:readSetting("DTAP_ZONE_CONFIG_EXT")
    self.ui:registerTouchZones({
        { id = ZONE_ID, ges = "tap", screen_zone = sz(z),
          overrides = { "tap_forward", "tap_backward" }, handler = open(false) },
        -- the top: the areas KOReader uses to open its menu
        { id = TOP_TAP_ID, ges = "tap", screen_zone = sz(menu_zone),
          overrides = { "readermenu_tap", "tap_forward", "tap_backward" }, handler = open(true) },
        { id = TOP_EXT_TAP_ID, ges = "tap", screen_zone = sz(menu_ext),
          overrides = { "readermenu_ext_tap", "readermenu_tap", TOP_TAP_ID, "tap_forward", "tap_backward" },
          handler = open(true) },
        -- the bottom: the areas of KOReader's settings panel (Aa opens it)
        { id = BOTTOM_TAP_ID, ges = "tap", screen_zone = sz(cfg_zone),
          overrides = { "readerconfigmenu_tap", "readerfooter_tap", "tap_forward", "tap_backward" },
          handler = open(true) },
        { id = BOTTOM_EXT_TAP_ID, ges = "tap", screen_zone = sz(cfg_ext),
          overrides = { "readerconfigmenu_ext_tap", "readerconfigmenu_tap", "readerfooter_tap", BOTTOM_TAP_ID,
                        "tap_forward", "tap_backward" },
          handler = open(true) },
    })
end

-- Links / highlights / corner taps first: other modules re-register their zones
-- at times, so the ordering is re-asserted after every (un)registration.
function Toolbar:fixZoneOrder()
    local ui = self.ui
    local dg = ui.touch_zone_dg
    if not dg then return end
    local changed = false
    for our_id, before in pairs(OUR_ZONES) do
        if dg:checkNode(our_id) then
            for _i, id in ipairs(before) do
                if dg:checkNode(id) then
                    dg:addNodeDep(our_id, id)
                    changed = true
                end
            end
        end
    end
    if changed then
        local ordered = {}
        for _i, zone_id in ipairs(dg:serialize()) do
            if ui._zones[zone_id] then table.insert(ordered, ui._zones[zone_id]) end
        end
        ui._ordered_touch_zones = ordered
    end
end

function Toolbar:hookZoneRegistration()
    local ui = self.ui
    if ui._bos_zones_hooked then return end
    ui._bos_zones_hooked = true
    local toolbar = self
    local orig_register = ui.registerTouchZones
    local orig_unregister = ui.unRegisterTouchZones
    ui.registerTouchZones = function(this, zones)
        orig_register(this, zones)
        local ok, err = pcall(toolbar.fixZoneOrder, toolbar)
        if not ok then logger.warn("ShelfTechUI: zone order:", err) end
    end
    ui.unRegisterTouchZones = function(this, zones)
        orig_unregister(this, zones)
        local ok, err = pcall(toolbar.fixZoneOrder, toolbar)
        if not ok then logger.warn("ShelfTechUI: zone order:", err) end
    end
end

-- No page-turn animation behind the toolbar (skimming, « »): the page turns
-- under the overlay; normal reading keeps its animation.
function Toolbar:hookPageAnimation()
    local view = self.ui.view
    if not view or view._bos_anim_hooked then return end
    view._bos_anim_hooked = true
    local toolbar = self
    local orig = view.onPageChangeAnimation
    if type(orig) ~= "function" then return end
    view.onPageChangeAnimation = function(this, forward)
        if toolbar.hud then
            local Screen = Device.screen
            if Screen.setSwipeAnimations then pcall(Screen.setSwipeAnimations, Screen, false) end
            return true
        end
        return orig(this, forward)
    end
end

-- ------------------------------------------------------------ the overlay

function Toolbar:showToolbar()
    if self.hud then return end
    local ok, hud = pcall(function()
        return require("bos_toolbar_widget"):new{ ui = self.ui, plugin = self }
    end)
    if not ok then
        logger.warn("ShelfTechUI: toolbar did not open:", hud)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("The reading toolbar couldn't open. Please send this to the developer:") .. "\n\n" .. tostring(hud):sub(1, 300) })
        return
    end
    self.hud = hud
    UIManager:show(self.hud)
end

function Toolbar:closeToolbar()
    if self.hud then
        UIManager:close(self.hud)
        self.hud = nil
    end
end

function Toolbar:toggle()
    if self.hud then self:closeToolbar() else self:showToolbar() end
end

function Toolbar:onToolbarClosed(widget)
    if self.hud == widget then self.hud = nil end
    if self.origin and self:getOriginPage() == self.ui:getCurrentPage() then
        self:clearOrigin()
    end
end

-- ------------------------------------------------------------ "return to page"

function Toolbar:setOriginIfNeeded()
    if self.origin then return end
    local ui = self.ui
    local location = ui.link:getCurrentLocation()
    local label
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        label = ui.pagemap:getCurrentPageLabel(true)
    end
    self.origin = { location = location, page = ui:getCurrentPage(), label = label }
    ui.link:addCurrentLocationToStack(location)
end

function Toolbar:clearOrigin()
    self.origin = nil
end

function Toolbar:getOriginPage()
    local o = self.origin
    if not o then return nil end
    if self.ui.rolling and o.location and o.location.xpointer then
        local ok, page = pcall(self.ui.document.getPageFromXPointer, self.ui.document, o.location.xpointer)
        if ok and page then return page end
    end
    return o.page
end

function Toolbar:goToPage(page)
    self:setOriginIfNeeded()
    self._navigating = true
    self.ui:handleEvent(Event:new("GotoPage", page))
    self._navigating = false
end

function Toolbar:goToOrigin()
    local o = self.origin
    if not o then return end
    self._navigating = true
    self.ui:handleEvent(Event:new("RestoreBookLocation", o.location))
    self._navigating = false
    local stack = self.ui.link.location_stack
    if stack and stack[#stack] == o.location then table.remove(stack) end
    self:clearOrigin()
end

-- ------------------------------------------------------------ reader events
-- (forwarded by the plugin)

function Toolbar:onPageUpdate()
    if self.hud then
        self.hud:onReaderPageUpdate()
    elseif self.origin and not self._navigating then
        self:clearOrigin() -- you turned a page yourself: that's your new spot
    end
end

function Toolbar:onCloseDocument()
    self:closeToolbar()
    self:clearOrigin()
end

function Toolbar:onSetDimensions()
    self:closeToolbar()
    if Device:isTouchDevice() then
        UIManager:nextTick(function() self:registerZones() end)
    end
end

function Toolbar:onCloseWidget()
    self:closeToolbar()
end

-- ------------------------------------------------------------ settings

Toolbar.ZONE_NAMES = {
    narrow = _("Narrow"),
    medium = _("Medium"),
    wide = _("Wide"),
    off = _("Off"),
}
Toolbar.ZONE_ORDER = { "narrow", "medium", "wide", "off" }

return Toolbar
