--[[--
The Settings app, as a phone's: a front page with a big title, a search field
and the sections as rows (an icon, the name, what's in it); each section a
page of its own, ‹ back to the front page. Rows stand in cards (iOS's inset
grouped lists), with a switch for on/off, a tick for a choice and the value
in grey on the right. Search looks through every setting as you type.

Items keep the exact semantics they have in KOReader's pull-down menu
(callbacks receive a TouchMenu-like object, `keep_menu_open`, `checked_func`,
`sub_item_table_func`, `tap_input`, ... are all honoured).
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen

local function S(n) return Screen:scaleBySize(n) end

local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
local GRAY_TEXT = Blitbuffer.COLOR_DARK_GRAY

-- ---------------------------------------------------------------------------
-- Small building blocks
-- ---------------------------------------------------------------------------

-- A fixed-size tappable area (tap + hold).
local Tappable = InputContainer:extend{
    width = nil, height = nil,
    callback = nil, hold_callback = nil, enabled = true,
}

function Tappable:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

-- Our own TapSelect/HoldSelect must not be propagated to children: a row's
-- ▲/▼ buttons are Tappables too and would otherwise grab the row's tap.
-- (Gestures themselves still reach children first, so the buttons work.)
function Tappable:handleEvent(event)
    if event.handler == "onTapSelect" or event.handler == "onHoldSelect" then
        local fn = self[event.handler]
        local args = event.args or { n = 0 }
        if fn then return fn(self, unpack(args, 1, args.n or #args)) end
        return
    end
    return InputContainer.handleEvent(self, event)
end

--- A tap: the row flashes (inverted, at once) so the tap is seen even when
--- what it opens takes a moment; then its action.
function Tappable:onTapSelect()
    if self.enabled ~= false and self.callback then
        local d = self.dimen
        if d and d.x and d.w > 0 and d.h > 0 then
            local bb = Screen.bb
            bb:invertRect(d.x, d.y, d.w, d.h)
            UIManager:setDirty(nil, "fast", d)
            UIManager:forceRePaint()
            bb:invertRect(d.x, d.y, d.w, d.h)
            UIManager:setDirty(nil, "fast", d)
        end
        self.callback()
    end
    return true
end

function Tappable:onHoldSelect()
    if self.hold_callback then
        self.hold_callback()
        return true
    end
end

-- Bookshelf's UI font, as every ShelfTechUI surface
local UI = require("bos_ui")
local function face(size) return UI.face(size) end
local function bface(size) return (UI.boldFace(size)) end
local function bflag(size) local _f, b = UI.boldFace(size) return b end


-- ---------------------------------------------------------------------------
-- Bookshelf-style design tokens (AndyHazz/bookshelf.koplugin): 2px black
-- outlines, the theme's corners, hard down-right drop shadow, grey hairlines.
-- ---------------------------------------------------------------------------

local Look = require("bos_look")
local LINE = Look.LINE          -- outline thickness
local RADIUS = Look.RADIUS      -- the theme's corners (Retro: square)
local HAIRLINE = Blitbuffer.COLOR_LIGHT_GRAY

--- A section heading: mono grey capitals and a dotted leader (Look.heading).
local Heading = require("ui/widget/widget"):extend{ width = nil, text = "", height = nil }
function Heading:getSize() return Geom:new{ w = self.width, h = self.height or S(26) } end
function Heading:paintTo(bb, x, y)
    Look.heading(bb, self.text, x, y, self.width, self.height or S(26))
end

-- Outlined rounded panel with an optional hard drop shadow. Painted as two
-- concentric rounded rects so the corners stay clean (as bookshelf does).
local Card = WidgetContainer:extend{
    bordersize = LINE, padding = 0, radius = RADIUS, shadow = 0,
    background = WHITE, color = BLACK,
}

function Card:getSize()
    local s = self[1]:getSize()
    local chrome = 2 * (self.bordersize + self.padding)
    return Geom:new{ w = s.w + chrome + self.shadow, h = s.h + chrome + self.shadow }
end

function Card:paintTo(bb, x, y)
    local sz = self:getSize()
    local w, h = sz.w - self.shadow, sz.h - self.shadow
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    local t = self.bordersize
    Look.box(bb, x, y, w, h, { border = t, shadow = self.shadow, color = self.color, fill = self.background })
    self[1]:paintTo(bb, x + t + self.padding, y + t + self.padding)
end

-- ----- controls, the way a phone draws them ----------------------------------

local Widget = require("ui/widget/widget")

--- An on/off switch (Android, iOS): a pill, filled with the knob at its
--- right when on; outlined with the knob at its left when off.
local Switch = Widget:extend{ on = false, enabled = true }
function Switch:getSize() return Geom:new{ w = S(50), h = S(28) } end
function Switch:paintTo(bb, x, y)
    local w, h = S(50), S(28)
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    local ink = self.enabled and BLACK or GRAY_TEXT
    local r = math.floor(h / 2)
    local b = math.max(LINE, S(2))
    if self.on then
        bb:paintRoundedRect(x, y, w, h, ink, r)
        Look.disc(bb, x + w - r, y + r, r - b - S(1), WHITE)
    else
        bb:paintRoundedRect(x, y, w, h, ink, r)
        bb:paintRoundedRect(x + b, y + b, w - 2 * b, h - 2 * b, WHITE, r - b)
        Look.disc(bb, x + r, y + r, r - b - S(3), ink)
    end
end

--- A choice in a list (iOS): a tick at the right of the one chosen; the
--- others, an empty ring (so it reads as a choice on paper too).
local Check = Widget:extend{ on = false, enabled = true }
function Check:getSize() return Geom:new{ w = S(28), h = S(28) } end
function Check:paintTo(bb, x, y)
    local d = S(28)
    self.dimen = Geom:new{ x = x, y = y, w = d, h = d }
    local ink = self.enabled and BLACK or GRAY_TEXT
    local r = math.floor(d / 2)
    if self.on then
        Look.disc(bb, x + r, y + r, r, ink)
        local t = TextWidget:new{ text = "\u{2713}", face = bface(16), bold = bflag(16), fgcolor = WHITE }
        local sz = t:getSize()
        t:paintTo(bb, x + math.floor((d - sz.w) / 2), y + math.floor((d - sz.h) / 2))
        t:free()
    else
        Look.disc(bb, x + r, y + r, r, HAIRLINE)
        Look.disc(bb, x + r, y + r, r - math.max(LINE, S(2)), WHITE)
    end
end

--- A section's icon on a small tile (iOS's coloured squares, in ink).
local IconTile = Widget:extend{ icon = nil, size = nil }
function IconTile:getSize() return Geom:new{ w = self.size, h = self.size } end
function IconTile:paintTo(bb, x, y)
    local d = self.size
    self.dimen = Geom:new{ x = x, y = y, w = d, h = d }
    local r = math.max(S(6), Look.RADIUS)
    bb:paintRoundedRect(x, y, d, d, BLACK, r)
    local isz = math.floor(d * 0.62)
    if self.icon then
        pcall(UI.paintIcon, bb, self.icon, x + math.floor((d - isz) / 2), y + math.floor((d - isz) / 2), isz, true)
    end
end

--- A bar down a row's left edge: the setting a search led to.
local Marker = Widget:extend{ h = 0 }
function Marker:getSize() return Geom:new{ w = S(5), h = self.h } end
function Marker:paintTo(bb, x, y) bb:paintRect(x, y + S(8), S(5), self.h - S(16), BLACK) end

-- ---------------------------------------------------------------------------
-- The screen
--
-- As a phone's Settings app: a front page with a big title, a search field
-- and the sections as rows (an icon, the name, what's in it); a section is a
-- page of its own with ‹ back to the front page. Rows stand in cards, a
-- switch for on/off, a tick for a choice, the value in grey on the right.
-- Search looks through every setting, sub-pages too (ShelfTechUI's and
-- KOReader's), as you type; a result opens the page it's on, the setting
-- marked.
-- ---------------------------------------------------------------------------

local HubScreen = InputContainer:extend{
    plugin = nil,            -- the bos_settings instance (data + actions)
    covers_fullscreen = true,
    stack = nil,
}

function HubScreen:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.margin = S(18)
    self.row_h = S(58)
    self.group_gap = S(16)
    self.footer_h = S(60)
    self.field_h = S(44)

    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        local Input = Device.input
        self.key_events = {
            Back = { { Input.group.Back } },
            NextPage = { { Input.group.PgFwd } },
            PrevPage = { { Input.group.PgBack } },
        }
    end

    -- TouchMenu look-alike handed to item callbacks.
    local screen = self
    self.ctx = setmetatable({
        updateItems = function() screen:render() end,
        closeMenu = function() screen:closeAll() end,
        backToUpperMenu = function(_, no_close) screen:back(no_close) end,
        -- plugins that open a sub-page themselves from a long-press (File
        -- browser plus: "long press for settings") call these on the menu
        onMenuSelect = function(_, item) screen:activate(item) return true end,
        onMenuHold = function(_, item) screen:hold(item) return true end,
        onMenuChoice = function(_, item) screen:activate(item) return true end,
        onBack = function() screen:back() return true end,
        onClose = function() screen:closeAll() return true end,
        show_parent = screen,
        item_table_stack = {},
    }, { __index = function(_, k)
        if k == "item_table" then
            local lvl = screen.stack[#screen.stack]
            return lvl and lvl.items
        end
        return screen[k]
    end })

    -- the search field: KOReader's own text input (keyboard layouts, a real
    -- keyboard, the cursor) inside our box
    local InputText = require("ui/widget/inputtext")
    self.input = InputText:new{
        text = "", hint = _("Search settings"),
        width = self:inputWidth(), face = face(17),
        bordersize = 0, margin = 0, padding = S(4),
        parent = self, focused = false,
        edit_callback = function(edited) if edited then self:onTyped() end end,
        enter_callback = function() self:hideKeyboard() end,
    }

    self.sections = self.plugin:getSections()
    self.stack = { self:rootLevel() }
    -- asked to open on a section (the store's "Libraries, formats and
    -- language"): once
    local Store = require("bos_settings_store")
    local want = Store.get("settings_open_at")
    if want then
        Store.set("settings_open_at", nil)
        for i, sec in ipairs(self.sections) do
            if sec.id == want then self:openSection(i) return end
        end
    end
    self:render()
end

--- The text's room in the field: the search page's (beside Cancel), less
--- the magnifier and the ×; the same on the front page.
function HubScreen:inputWidth()
    local cancel = TextWidget:new{ text = _("Cancel"), face = face(17) }
    local cw = cancel:getSize().w + S(24)
    cancel:free()
    return self.W - 2 * self.margin - cw - S(6) - 2 * LINE - Look.SHADOW_SMALL - S(44) - S(44) - S(6)
end

-- ----- navigation -----------------------------------------------------------

--- What a section holds, in a few words (its headings, else its first rows),
--- as Android says under each section.
local SUMMARY
local function summary(sec)
    if not SUMMARY then
        SUMMARY = {
            stui_home = _("Layout, status bar, library, start menu"),
            stui_reading = _("Toolbar, Quick Settings, navigation, typesetting"),
            stui_look = _("Themes, interface size, KOReader's screens"),
            stui_connect = _("Transfer, store, Hardcover, recommendations"),
            stui_device = _("Light, night mode, Wi-Fi, screen, keyboard"),
            stui_tools = _("Statistics, Calibre, highlights, look-up"),
            stui_system = _("Updates, shortcuts, power, about"),
        }
    end
    if SUMMARY[sec.id] then return SUMMARY[sec.id] end
    local heads, rows = {}, {}
    for _i, it in ipairs(sec.items or {}) do
        if it.heading then
            if it.heading ~= sec.name then heads[#heads + 1] = it.heading end
        elseif it.text ~= "KOMenu:separator" and #rows < 4 then
            local ok, t = pcall(function() return it.text_func and it.text_func() or it.text end)
            if ok and type(t) == "string" and t ~= "" then rows[#rows + 1] = t end
        end
    end
    local list = #heads >= 2 and heads or rows
    local out = {}
    for i = 1, math.min(4, #list) do out[i] = list[i] end
    return table.concat(out, ", ")
end

--- The front page: the sections, as rows.
function HubScreen:rootLevel()
    local level = { kind = "root", title = _("Settings"), page = 1 }
    level.build = function()
        local elements = {}
        local w = self:innerWidth()
        for i, sec in ipairs(self.sections) do
            -- ShelfTechUI's own sections, then the device's and KOReader's
            local group = i <= 4 and 1 or 2
            local spec = { text = sec.name, description = summary(sec), has_sub = true, icon = sec.icon,
                callback = function() self:openSection(i) end }
            spec.h = self:rowHeight(spec, w)
            table.insert(elements, { kind = "row", group = group, spec = spec })
        end
        return elements
    end
    return level
end

--- Open section `idx` from the front page.
function HubScreen:openSection(idx)
    local sec = self.sections[idx]
    if not sec then return end
    self.section_idx = idx
    self.stack = { self.stack[1] or self:rootLevel(),
        { kind = "list", title = sec.name, items = sec.items, page = 1 } }
    self:render()
end

function HubScreen:push(level)
    level.page = level.page or 1
    table.insert(self.stack, level)
    self:render()
end

function HubScreen:back(no_close)
    if self:keyboardUp() then
        self:hideKeyboard()
        return
    end
    if #self.stack > 1 then
        local gone = table.remove(self.stack)
        if gone.kind == "search" then self:clearField() end
        local lvl = self.stack[#self.stack]
        if lvl and lvl.rebuild then
            local ok, items = pcall(lvl.rebuild)
            if ok and type(items) == "table" then lvl.items = items end
        end
        self:render()
    elseif not no_close then
        self:closeAll()
    end
end

--- Back to level `depth` (1: the front page).
function HubScreen:popTo(depth)
    while #self.stack > depth do table.remove(self.stack) end
    self:render()
end

function HubScreen:closeAll()
    self:hideKeyboard(true)
    -- (an editor opened from a row may have taken this screen off the stack
    -- and put it back itself, as Bookshelf's line editors do: by then the
    -- plugin had let go of it, and asking the plugin to close it did nothing)
    if self.plugin.screen == self then
        self.plugin:closeHub()
    else
        UIManager:close(self)
    end
end

function HubScreen:onBack() self:back() return true end

function HubScreen:onNextPage() self:gotoPage(1, true) return true end

function HubScreen:onPrevPage() self:gotoPage(-1, true) return true end

function HubScreen:onSwipe(arg, ges)
    local dir = ges.direction
    if dir == "west" then
        self:gotoPage(1, false)
        return true
    elseif dir == "east" then
        -- (on a page's first page: back, as a phone's edge swipe)
        local lvl = self.stack[#self.stack]
        if (lvl.page or 1) <= 1 and #self.stack > 1 then self:back() else self:gotoPage(-1, false) end
        return true
    elseif dir == "south" and self:keyboardUp() then
        self:hideKeyboard()
        return true
    end
end

function HubScreen:gotoPage(delta, wrap)
    local lvl = self.stack[#self.stack]
    local n = self.page_count or 1
    local p = lvl.page + delta
    if wrap then
        if p > n then p = 1 elseif p < 1 then p = n end
    end
    p = math.max(1, math.min(n, p))
    if p ~= lvl.page then
        lvl.page = p
        self:render()
    end
end

-- ----- the search field ------------------------------------------------------

function HubScreen:keyboardUp()
    return self.input and self.input:isKeyboardVisible() or false
end

--- KOReader's text input calls this when it's tapped.
function HubScreen:onSwitchFocus() self:startSearch() end
function HubScreen:getFocusableWidgetXY() return nil end

--- The search page, the keyboard up.
function HubScreen:startSearch()
    local lvl = self.stack[#self.stack]
    if lvl.kind ~= "search" then
        self:push{ kind = "search", title = _("Search"), page = 1 }
    end
    if not self:keyboardUp() then
        self.is_always_active = true -- taps reach us under the keyboard
        self.input:focus()
        self.input:onShowKeyboard()
    end
    self:render()
end

function HubScreen:hideKeyboard(quiet)
    if not self:keyboardUp() then return end
    self.input:onCloseKeyboard()
    self.input:unfocus()
    self.is_always_active = nil
    if not quiet then self:render() end
end

function HubScreen:clearField()
    self.setting_text = true
    self.input:setText("")
    self.setting_text = nil
end

function HubScreen:onTyped()
    if self.setting_text then return end
    local lvl = self.stack[#self.stack]
    if lvl.kind ~= "search" then self:push{ kind = "search", title = _("Search"), page = 1 } lvl = self.stack[#self.stack] end
    lvl.page = 1
    -- (a burst of keys: looked up once it pauses)
    self._typed = self._typed or function() if self.stack[#self.stack].kind == "search" then self:render() end end
    UIManager:unschedule(self._typed)
    UIManager:scheduleIn(0.15, self._typed)
end

-- ----- item semantics (port of TouchMenu:onMenuSelect / onMenuHold) ---------

local function itemText(item)
    local text = item.text_func and item.text_func() or item.text
    return text and tostring(text) or ""
end

local function itemEnabled(item)
    local enabled = item.enabled
    if item.enabled_func then enabled = item.enabled_func() end
    return enabled ~= false
end

function HubScreen:subTable(item)
    return item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
end

function HubScreen:activate(item)
    if not itemEnabled(item) then return end

    if item.tap_input or item.tap_input_func then
        if not item.keep_menu_open then self:closeAll() end
        self:onInput(item.tap_input or item.tap_input_func())
        return
    end

    local sub = self:subTable(item)
    if sub then
        if #sub > 0 then
            self:push{ kind = "list", title = item.page_title or itemText(item), items = sub,
                -- a page built by a function is built again when come back to
                -- (what was done below it may have changed it)
                rebuild = item.sub_item_table_func }
        end
        return
    end

    local callback = item.callback_func and item.callback_func() or item.callback
    if callback then
        callback(self.ctx)
        if item.checked or item.checked_func then
            if not (item.check_callback_updates_menu or item.check_callback_closes_menu) then
                self:render()
            end
        elseif not item.keep_menu_open then
            self:closeAll()
        end
    end
end

function HubScreen:hold(item)
    if item.hold_input or item.hold_input_func then
        if item.hold_keep_menu_open == false then self:closeAll() end
        self:onInput(item.hold_input or item.hold_input_func())
        return
    end
    local hold_callback = item.hold_callback_func and item.hold_callback_func() or item.hold_callback
    if hold_callback then
        if item.hold_keep_menu_open == false then self:closeAll() end
        hold_callback(self.ctx, item)
        return
    end
    local help = item.help_text_func and item.help_text_func(self.ctx) or item.help_text
    if help then
        UIManager:show(InfoMessage:new{ text = help })
    end
end

-- ----- levels ---------------------------------------------------------------

-- A line of explanation for KOReader's own rows that have none, so every
-- section reads the same way. Keyed by KOReader's (translated) row text.
local KNOWN
local function known(text)
    if not KNOWN then
        KNOWN = {
            [_("Frontlight")] = _("Brightness and warmth of the light."),
            [_("Night mode")] = _("White on black, everywhere."),
            [_("Network")] = _("Wi-Fi, proxy, and what happens to Wi-Fi when the device sleeps."),
            [_("Screen")] = _("Refresh rate, rotation, sleep screen, colour and e-ink tuning."),
            [_("Taps and gestures")] = _("What taps, swipes and multi-finger gestures do, and where."),
            [_("Navigation")] = _("Page turns, the back key, and where a book opens."),
            [_("Document")] = _("Saving, end-of-book and highlight behaviour for every book."),
            [_("Language")] = _("The interface language."),
            [_("Device")] = _("Keys, sleep, time and date, and this device's own options."),
            [_("History")] = _("Every book you've opened, newest first."),
            [_("Open last document")] = _("Straight back into the last book."),
            [_("Favorites")] = _("The books you've starred."),
            [_("Collections")] = _("Your own lists of books."),
            [_("Bookmark browser")] = _("Bookmarks and highlights across all your books."),
            [_("Help")] = _("KOReader's guide, version and update check."),
            [_("Exit")] = _("Sleep, restart or leave KOReader."),
            [_("Read timer")] = _("An alarm after so many minutes of reading."),
            [_("Calibre")] = _("Wireless connection to Calibre on your computer."),
            [_("Export highlights")] = _("Send highlights and notes to a file or a service."),
            [_("Reading statistics")] = _("Time read, pages, the calendar, and their settings."),
            [_("Cloud storage")] = _("Dropbox, WebDAV and FTP folders."),
            [_("Move to archive")] = _("Move or copy the open book to an archive folder."),
            [_("Wallabag")] = _("Articles saved to read later."),
            [_("News downloader (RSS/Atom)")] = _("Feeds, downloaded as books."),
            [_("Text editor")] = _("Open and edit plain-text files."),
            [_("Dictionary lookup")] = _("Look a word up."),
            [_("Dictionary lookup history")] = _("The words you've looked up."),
            [_("Vocabulary builder")] = _("Review the words you've looked up."),
            [_("Wikipedia lookup")] = _("Look something up on Wikipedia."),
            [_("File search")] = _("Find a book by its file name."),
            [_("Fulltext search")] = _("Find words in this book."),
            [_("Translate current page")] = _("This page, in another language."),
            [_("Display mode")] = _("The file browser as a list or as covers."),
            [_("Edit shelves…")] = _("Add, remove and order the shelves on home."),
            [_("Close Bookshelf")] = _("Back to KOReader's own file browser."),
        }
    end
    return KNOWN[text]
end

-- Turn a KOReader menu table into row elements. Two extras for ShelfTechUI's
-- own pages: `description` (a grey explanation under the row) and
-- `heading` (a bold grey section title, no row).
-- A row's height depends only on its words and width: worked out once per
-- item (weak: an item dropped with its menu is forgotten).
local height_cache = setmetatable({}, { __mode = "k" })

--- The live parts of a row (checked, value, enabled, its own widget): asked
--- only for the rows on the page being shown.
function HubScreen:liveSpec(el)
    local item, spec = el.item, el.spec
    if not item or spec.live then return spec end
    spec.live = true
    spec.enabled = itemEnabled(item)
    spec.value = item.mandatory_func and item.mandatory_func() or item.mandatory
    spec.right_widget = item.right_widget_func and item.right_widget_func() or nil
    if item.checked_func then
        spec.checkable = true
        spec.checked = item.checked_func() and true or false
        spec.radio = item.radio
    end
    return spec
end

function HubScreen:itemElements(items, w)
    local elements, group = {}, 1
    for __, item in ipairs(items) do
        if item.heading then
            group = group + 1
            table.insert(elements, { kind = "label", text = item.heading })
        else
            local text = itemText(item)
            if item.text ~= "KOMenu:separator" and (text ~= "" or item.icon) then
                local desc = item.description_func and item.description_func() or item.description
                -- KOReader's own rows: the first sentence of their help, as
                -- ShelfTechUI's rows have a line of explanation
                if not desc and type(item.help_text) == "string" then
                    local first = item.help_text:gsub("%s+", " "):match("^(.-[%.!?])%s") or item.help_text:gsub("%s+", " ")
                    if #first > 150 then first = first:sub(1, 147):gsub("[\128-\191]*$", "") .. "…" end
                    desc = first
                end
                if not desc then desc = known(text) end
                local spec = {
                    text = text,
                    description = desc,
                    has_sub = item.sub_item_table ~= nil or item.sub_item_table_func ~= nil,
                    checkable = item.checked_func ~= nil,
                    callback = function() self:activate(item) end,
                    hold_callback = function() self:hold(item) end,
                }
                local lvl = self.stack[#self.stack]
                if lvl and lvl.target_item == item then spec.highlight = true end
                local hc = height_cache[item]
                if not (hc and hc.w == w and hc.desc == desc and hc.text == text) then
                    -- (the value chip narrows the words: measured with it, once)
                    local probe = { text = text, description = desc, has_sub = spec.has_sub,
                        checkable = spec.checkable, radio = item.radio,
                        value = item.mandatory_func and item.mandatory_func() or item.mandatory }
                    hc = { w = w, desc = desc, text = text, h = self:rowHeight(probe, w) }
                    height_cache[item] = hc
                end
                spec.h = hc.h
                table.insert(elements, { kind = "row", group = group, spec = spec, item = item })
            end
            if item.separator then group = group + 1 end
        end
    end
    return elements
end

-- ----- the index -------------------------------------------------------------

local Utf8Proc
local function norm(s)
    s = tostring(s or "")
    if Utf8Proc == nil then
        local ok, m = pcall(require, "ffi/utf8proc")
        Utf8Proc = ok and m or false
    end
    if Utf8Proc and Utf8Proc.lowercase then
        local ok, low = pcall(Utf8Proc.lowercase, s)
        s = ok and low or s:lower()
    else
        s = s:lower()
    end
    -- "Wi-Fi" is "wifi", "e-ink" "eink"; other marks are spaces
    s = s:gsub("[%-'\u{2019}]", ""):gsub("[%p]", " "):gsub("%s+", " ")
    return s
end

--- Every setting, once (sub-pages too, as KOReader's own menu search walks
--- them): { text, desc, trail, sec, chain = { { item, items } }, item }.
function HubScreen:buildIndex()
    if self.index then return self.index end
    local index, seen = {}, {}
    local function walk(items, sec_i, chain, trail, depth)
        if type(items) ~= "table" or items.ignored_by_menu_search or depth > 8 then return end
        for _i, item in ipairs(items) do
            if type(item) == "table" and not item.heading and item.text ~= "KOMenu:separator"
                    and not item.ignored_by_menu_search and not seen[item] then
                seen[item] = true
                local okT, text = pcall(itemText, item)
                if okT and text ~= "" then
                    local desc = item.description
                    if not desc and item.description_func then
                        local okD, d = pcall(item.description_func) desc = okD and d or nil
                    end
                    if not desc and type(item.help_text) == "string" then desc = item.help_text end
                    desc = desc or known(text)
                    local e = { text = text, desc = type(desc) == "string" and desc or nil, trail = trail,
                        sec = sec_i, chain = chain, item = item, siblings = #items }
                    e.n_text = norm(text)
                    e.n_all = e.n_text .. " | " .. norm(table.concat(trail, " ")) .. " | " .. norm(e.desc or "")
                    index[#index + 1] = e
                    local sub = item.sub_item_table
                    if item.stui_search_shallow then sub = nil
                    elseif item.sub_item_table_func then
                        local okS, s = pcall(item.sub_item_table_func)
                        sub = okS and s or nil
                    end
                    if type(sub) == "table" and #sub > 0 then
                        local c2 = { unpack(chain) }
                        c2[#c2 + 1] = { item = item, items = sub }
                        local t2 = { unpack(trail) }
                        t2[#t2 + 1] = text
                        walk(sub, sec_i, c2, t2, depth + 1)
                    end
                end
            end
        end
    end
    for i, sec in ipairs(self.sections) do
        index[#index + 1] = { text = sec.name, desc = summary(sec), trail = {}, sec = i, chain = {}, section = true,
            n_text = norm(sec.name), n_all = norm(sec.name) }
        walk(sec.items, i, {}, { sec.name }, 1)
    end
    self.index = index
    return index
end

--- The settings matching `q`: every word somewhere (its name, the way to it,
--- its explanation), the best first: a name that starts with it, a word of
--- the name that does, the name holding it, then the rest.
function HubScreen:search(q)
    local words = {}
    for wd in norm(q):gmatch("%S+") do words[#words + 1] = wd end
    if #words == 0 then return {} end
    local out = {}
    for _i, e in ipairs(self:buildIndex()) do
        local score, ok = 0, true
        for k, wd in ipairs(words) do
            local at = e.n_all:find(wd, 1, true)
            if not at then ok = false break end
            local t = e.n_text:find(wd, 1, true)
            if t == 1 then score = score + (k == 1 and 8 or 4)
            elseif t and e.n_text:sub(t - 1, t - 1) == " " then score = score + 4
            elseif t then score = score + 2
            else score = score + 1 end
        end
        if ok then
            if e.section then score = score + 3 end
            -- a name in a long list is mostly a catalogue (the tiles you can
            -- add, the languages): the setting itself comes before it
            if (e.siblings or 0) > 15 then score = score - 1.5 end
            out[#out + 1] = { e = e, score = score - #e.chain * 0.3 }
        end
    end
    table.sort(out, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.e.text < b.e.text
    end)
    local res = {}
    for i = 1, math.min(80, #out) do res[i] = out[i].e end
    return res
end

--- Open the page a search result is on, the setting marked.
function HubScreen:goTo(e)
    self:hideKeyboard(true)
    self:clearField()
    local sec = self.sections[e.sec]
    self.section_idx = e.sec
    self.stack = { self.stack[1], { kind = "list", title = sec.name, items = sec.items, page = 1 } }
    for _i, step in ipairs(e.chain or {}) do
        table.insert(self.stack, { kind = "list", title = itemText(step.item), items = step.items, page = 1,
            rebuild = step.item.sub_item_table_func })
    end
    if e.item then self.stack[#self.stack].target_item = e.item end
    self:render()
end

--- The search page's rows.
function HubScreen:searchElements(w)
    local q = (self.input:getText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then
        return { { kind = "note", text = _("Every setting, ShelfTechUI's and KOReader's, sub-pages too: type a word or two.") } }
    end
    local found = self:search(q)
    if #found == 0 then
        return { { kind = "note", text = T(_("No settings match \u{201C}%1\u{201D}."), q) } }
    end
    local elements = { { kind = "label", text = T(_("%1 found"), #found) } }
    for _i, e in ipairs(found) do
        local where = #e.trail > 0 and table.concat(e.trail, "  \u{203A}  ") or _("Section")
        local spec = { text = e.text, description = where, icon = e.section and self.sections[e.sec].icon or nil,
            has_sub = true, callback = function() self:goTo(e) end }
        spec.h = self:rowHeight(spec, w)
        table.insert(elements, { kind = "row", group = 1, spec = spec })
    end
    return elements
end

--- Open `tab` (a KOReader menu) on its section and walk the item indexes in
--- `path` (as found by KOReader's menu search): intermediate indexes open
--- sub-pages, the last one is shown marked.
function HubScreen:openPath(tab, path)
    local idx
    for i, sec in ipairs(self.sections) do
        if sec.items == tab then idx = i end
        for _j, t in ipairs(sec.tabs or {}) do if t == tab then idx = i end end
    end
    local root = self.stack[1] or self:rootLevel()
    if idx then
        self.section_idx = idx
        self.stack = { root, { kind = "list", title = self.sections[idx].name, items = tab, page = 1 } }
    else
        self.stack = { root, { kind = "list", title = self.plugin:tabName(tab), items = tab, page = 1 } }
    end
    local items = tab
    for i, n in ipairs(path) do
        local item = items[n]
        if not item then break end
        if i == #path then
            self.stack[#self.stack].target_item = item
            break
        end
        local sub = self:subTable(item)
        if not sub or #sub == 0 then break end
        table.insert(self.stack, { kind = "list", title = itemText(item), items = sub, page = 1 })
        items = sub
    end
    self:render()
end

-- ----- laying out a page -----------------------------------------------------

-- a card's own edges (outline above and below, its shadow)
local function cardChrome() return 2 * LINE + Look.SHADOW_SMALL end

function HubScreen:gapBefore(prev, el)
    if not prev then return el.kind == "row" and cardChrome() or 0 end
    if el.kind == "label" or el.kind == "note" then return S(18) end
    if prev.kind == "label" then return S(6) + cardChrome() end
    if el.kind == "row" and prev.kind == "row" and el.group == prev.group then
        return Size.line.medium
    end
    return self.group_gap + cardChrome()
end

function HubScreen:elementHeight(el)
    if el.kind == "row" then return el.spec.h or self.row_h end
    if el.kind == "note" then return S(90) end
    return S(26)
end

function HubScreen:paginate(elements, avail)
    local pages, cur, used = {}, {}, 0
    for __, el in ipairs(elements) do
        local prev = cur[#cur]
        local need = self:gapBefore(prev, el) + self:elementHeight(el)
        -- a heading never ends a page
        if #cur > 0 and (used + need > avail
                or (el.kind == "label" and used + need + self.row_h > avail)) then
            table.insert(pages, cur)
            cur, used = {}, 0
            need = self:gapBefore(nil, el) + self:elementHeight(el)
        end
        table.insert(cur, el)
        used = used + need
    end
    if #cur > 0 or #pages == 0 then table.insert(pages, cur) end
    return pages
end

local PAD = 14 -- a row's inner margin (scaled)

-- The right-hand side of a row: [value] [switch | tick | ›]
function HubScreen:rightGroup(spec, w)
    local enabled = spec.enabled ~= false
    local right_group = HorizontalGroup:new{ align = "center" }
    if spec.right_widget then
        table.insert(right_group, spec.right_widget)
        if spec.checkable or spec.has_sub then table.insert(right_group, HorizontalSpan:new{ width = S(10) }) end
    end
    if spec.value then
        table.insert(right_group, TextWidget:new{ text = tostring(spec.value), face = face(16),
            fgcolor = GRAY_TEXT, max_width = math.floor(w * 0.36) })
        if spec.checkable or spec.has_sub then table.insert(right_group, HorizontalSpan:new{ width = S(8) }) end
    end
    if spec.checkable then
        if spec.radio then
            table.insert(right_group, Check:new{ on = spec.checked, enabled = enabled })
        else
            table.insert(right_group, Switch:new{ on = spec.checked, enabled = enabled })
        end
    elseif spec.has_sub then
        table.insert(right_group, IconWidget:new{ icon = "chevron.right", width = S(20), height = S(20), dim = not enabled })
    end
    return right_group
end

function HubScreen:iconSize() return S(36) end

function HubScreen:textWidth(spec, w)
    local right_w = self:rightGroup(spec, w):getSize().w
    local icon_w = spec.icon and (self:iconSize() + S(12)) or 0
    return w - 2 * S(PAD) - icon_w - right_w - (right_w > 0 and S(12) or 0)
end

--- A row's height: one line, or more with its description.
function HubScreen:rowHeight(spec, w)
    if not spec.description then return self.row_h end
    local tb = TextBoxWidget:new{ text = spec.description, face = face(15), width = self:textWidth(spec, w) }
    local dh = tb:getSize().h
    tb:free()
    return math.max(self.row_h, S(12) + S(27) + dh + S(12))
end

-- A row: [icon] title, its description under it in grey ..... [value][control]
function HubScreen:makeRow(spec, w)
    local h = spec.h or self.row_h
    local pad = S(PAD)
    local enabled = spec.enabled ~= false
    local right_group = self:rightGroup(spec, w)
    local text_max = self:textWidth(spec, w)
    local text_w = TextWidget:new{
        text = spec.text, face = face(19), max_width = text_max,
        bold = spec.highlight or spec.bold,
        fgcolor = enabled and BLACK or GRAY_TEXT,
    }
    local left
    if spec.description then
        left = VerticalGroup:new{
            align = "left",
            text_w,
            VerticalSpan:new{ width = S(2) },
            TextBoxWidget:new{ text = spec.description, face = face(15), width = text_max, fgcolor = GRAY_TEXT },
        }
    else
        left = text_w
    end
    local lead = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = pad } }
    if spec.icon then
        table.insert(lead, IconTile:new{ icon = spec.icon, size = self:iconSize() })
        table.insert(lead, HorizontalSpan:new{ width = S(12) })
    end
    table.insert(lead, left)
    local dim = Geom:new{ w = w, h = h }
    local content = OverlapGroup:new{
        dimen = dim:copy(),
        LeftContainer:new{ dimen = dim:copy(), lead },
        RightContainer:new{ dimen = dim:copy(),
            HorizontalGroup:new{ right_group, HorizontalSpan:new{ width = pad } } },
    }
    if spec.highlight then table.insert(content, 1, Marker:new{ h = h }) end
    return Tappable:new{
        width = w, height = h,
        enabled = enabled,
        callback = spec.callback,
        hold_callback = spec.hold_callback,
        content,
    }
end

-- A group of rows in a card (iOS's inset grouped list): hairlines between
-- rows, starting where the words do.
function HubScreen:makeCard(rows, card_w)
    local inner_w = card_w - 2 * LINE - Look.SHADOW_SMALL
    local vg = VerticalGroup:new{ align = "left" }
    for i, spec in ipairs(rows) do
        if i > 1 then
            local inset = S(PAD) + (spec.icon and (self:iconSize() + S(12)) or 0)
            table.insert(vg, HorizontalGroup:new{
                HorizontalSpan:new{ width = inset },
                LineWidget:new{ dimen = Geom:new{ w = inner_w - inset, h = Size.line.medium }, background = HAIRLINE } })
        end
        table.insert(vg, self:makeRow(spec, inner_w))
    end
    return Card:new{ bordersize = LINE, shadow = Look.SHADOW_SMALL, vg }
end

function HubScreen:bodyWidth()
    return self.W - 2 * self.margin
end

--- The width of a row inside its card.
function HubScreen:innerWidth()
    return self:bodyWidth() - 2 * LINE - Look.SHADOW_SMALL
end

function HubScreen:buildBody(page, avail_w)
    local body = VerticalGroup:new{ align = "left" }
    local prev
    local card_rows = {}
    local function flush()
        if #card_rows > 0 then
            table.insert(body, self:makeCard(card_rows, avail_w))
            card_rows = {}
        end
    end
    for __, el in ipairs(page) do
        if el.kind == "row" then
            if not (prev and prev.kind == "row" and prev.group == el.group) then
                flush()
                local gap = self:gapBefore(prev, el) - cardChrome()
                if gap > 0 then table.insert(body, VerticalSpan:new{ width = gap }) end
            end
            table.insert(card_rows, self:liveSpec(el))
        else
            flush()
            local gap = self:gapBefore(prev, el)
            if gap > 0 then table.insert(body, VerticalSpan:new{ width = gap }) end
            if el.kind == "label" then
                table.insert(body, Heading:new{ width = avail_w, text = el.text })
            elseif el.kind == "note" then
                table.insert(body, TextBoxWidget:new{ text = el.text, face = face(17), width = avail_w,
                    fgcolor = GRAY_TEXT, alignment = "center" })
            end
        end
        prev = el
    end
    flush()
    return body
end

-- ----- around the page: the status line, the header, the page keys -----------

-- Bookshelf's status line: the same one as on the shelf, in Quick Settings
-- and on the reading toolbar.
function HubScreen:buildStatusLine(w)
    local row = UI.buildStatusRow(w)
    if row then return row end
    return VerticalSpan:new{ width = S(10) }
end

--- A key: a glyph or a word in a box (the theme's), on its shadow.
function HubScreen:key(label, cb, opts)
    opts = opts or {}
    local h = opts.h or S(40)
    local inner
    if opts.glyph then
        inner = TextWidget:new{ text = label, face = UI.symbolFace(UI.ptForPx(math.floor(h * 0.4))) }
    else
        inner = TextWidget:new{ text = label, face = opts.face or face(17), bold = opts.bold }
    end
    local w = opts.w or math.max(h, inner:getSize().w + S(24))
    local card = Card:new{ bordersize = opts.plain and 0 or LINE, shadow = opts.plain and 0 or Look.SHADOW_SMALL,
        CenterContainer:new{ dimen = Geom:new{ w = w - (opts.plain and 0 or 2 * LINE), h = h - (opts.plain and 0 or 2 * LINE) }, inner } }
    local sz = card:getSize()
    return Tappable:new{ width = sz.w, height = sz.h, callback = cb, card }
end

--- The search field: [magnifier  text …  ×]
function HubScreen:searchField(w)
    local h = self.field_h
    local inner_w = w - 2 * LINE - Look.SHADOW_SMALL
    local glyph = TextWidget:new{ text = UI.GLYPH.search, face = UI.symbolFace(UI.ptForPx(math.floor(h * 0.36))), fgcolor = GRAY_TEXT }
    local has_text = (self.input:getText() or "") ~= ""
    local clear_w = has_text and S(44) or 0
    local row = HorizontalGroup:new{ align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = S(44), h = h - 2 * LINE }, glyph },
        self.input,
    }
    if has_text then
        local d = S(26)
        local x_btn = Tappable:new{ width = clear_w, height = h - 2 * LINE,
            callback = function()
                self:clearField()
                self.stack[#self.stack].page = 1
                self:render()
            end,
            CenterContainer:new{ dimen = Geom:new{ w = clear_w, h = h - 2 * LINE },
                Card:new{ bordersize = 0, background = GRAY_TEXT,
                    CenterContainer:new{ dimen = Geom:new{ w = d, h = d },
                        TextWidget:new{ text = "\u{00D7}", face = bface(16), bold = bflag(16), fgcolor = WHITE } } } } }
        table.insert(row, HorizontalSpan:new{ width = math.max(0, inner_w - S(44) - self.input:getSize().w - clear_w) })
        table.insert(row, x_btn)
    end
    local field = Card:new{ bordersize = LINE, shadow = Look.SHADOW_SMALL,
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = h - 2 * LINE }, row } }
    -- a tap anywhere on it starts a search (not just on the words)
    local sz = field:getSize()
    return Tappable:new{ width = sz.w, height = sz.h, callback = function() self:startSearch() end, field }
end

--- Above the page.
---   front page:  Settings (big)                         [×]
---                [ search                              ]
---   a page:      [‹ Settings]                       [⌕] [×]
---                Typesetting (big)
---   search:      [ search …                ×] [Cancel]
function HubScreen:pageHeader(w)
    local vg = VerticalGroup:new{ align = "left" }
    local lvl = self.stack[#self.stack]
    local close = self:key("\u{00D7}", function() self:closeAll() end, { face = bface(22), bold = bflag(22) })
    local function spread(left, right)
        local lw = left:getSize().w
        local rw = right:getSize().w
        return HorizontalGroup:new{ align = "center", left, HorizontalSpan:new{ width = math.max(0, w - lw - rw) }, right }
    end
    if lvl.kind == "root" then
        local title = TextWidget:new{ text = _("Settings"), face = bface(30), bold = bflag(30), max_width = w - S(80) }
        table.insert(vg, spread(title, close))
        table.insert(vg, VerticalSpan:new{ width = S(12) })
        table.insert(vg, self:searchField(w))
        table.insert(vg, VerticalSpan:new{ width = S(4) })
    elseif lvl.kind == "search" then
        local cancel = self:key(_("Cancel"), function()
            self:hideKeyboard(true)
            self:clearField()
            self:popTo(math.max(1, #self.stack - 1))
        end, { plain = true, h = self.field_h + Look.SHADOW_SMALL })
        local fw = w - cancel:getSize().w - S(6)
        table.insert(vg, HorizontalGroup:new{ align = "center", self:searchField(fw), HorizontalSpan:new{ width = S(6) }, cancel })
        table.insert(vg, VerticalSpan:new{ width = S(4) })
    else
        local prev = self.stack[#self.stack - 1]
        local back_text = TextWidget:new{ text = "\u{2039}  " .. (prev and prev.title or _("Settings")),
            face = face(18), max_width = math.floor(w * 0.55) }
        local back = Tappable:new{ width = back_text:getSize().w + S(16), height = S(40), callback = function() self:back() end,
            LeftContainer:new{ dimen = Geom:new{ w = back_text:getSize().w + S(16), h = S(40) }, back_text } }
        local find = self:key(UI.GLYPH.search, function() self:startSearch() end, { glyph = true })
        local right = HorizontalGroup:new{ align = "center", find, HorizontalSpan:new{ width = S(10) }, close }
        table.insert(vg, spread(back, right))
        table.insert(vg, VerticalSpan:new{ width = S(6) })
        table.insert(vg, TextWidget:new{ text = lvl.title or "", face = bface(26), bold = bflag(26), max_width = w })
    end
    table.insert(vg, VerticalSpan:new{ width = S(6) })
    return vg
end

-- Footer: the page keys, when there's more than one page.
function HubScreen:buildFooter(page, count, w)
    local h = self.footer_h
    if count <= 1 then return VerticalSpan:new{ width = h } end
    local cell = S(54)
    local function btn(icon, cb, enabled)
        local bw, bh = S(44), S(38)
        local face_ = Card:new{ bordersize = LINE, color = enabled and BLACK or GRAY_TEXT,
            shadow = enabled and Look.SHADOW_SMALL or 0,
            CenterContainer:new{ dimen = Geom:new{ w = bw - 2 * LINE, h = bh - 2 * LINE },
                IconWidget:new{ icon = icon, width = S(22), height = S(22), dim = not enabled } } }
        return Tappable:new{ width = cell, height = h, enabled = enabled, callback = cb,
            CenterContainer:new{ dimen = Geom:new{ w = cell, h = h }, face_ } }
    end
    local mid_w = w - 4 * cell
    -- page dots, as a phone shows pages (a number past a dozen)
    local label
    if count <= 12 then
        local dots = {}
        for i = 1, count do dots[i] = i == page and "\u{25CF}" or "\u{25CB}" end
        label = TextWidget:new{ text = table.concat(dots, " "), face = face(14), max_width = mid_w }
    else
        label = TextWidget:new{ text = string.format("%d / %d", page, count), face = Look.mono(16), bold = true, max_width = mid_w }
    end
    return HorizontalGroup:new{
        align = "center",
        btn("chevron.first", function() self:gotoFirstLast(-1) end, page > 1),
        btn("chevron.left", function() self:gotoPage(-1, false) end, page > 1),
        CenterContainer:new{ dimen = Geom:new{ w = mid_w, h = h }, label },
        btn("chevron.right", function() self:gotoPage(1, false) end, page < count),
        btn("chevron.last", function() self:gotoFirstLast(1) end, page < count),
    }
end

function HubScreen:gotoFirstLast(dir)
    local lvl = self.stack[#self.stack]
    local p = dir < 0 and 1 or (self.page_count or 1)
    if p ~= lvl.page then
        lvl.page = p
        self:render()
    end
end

function HubScreen:render()
    local lvl = self.stack[#self.stack]
    local full_w = self:bodyWidth()
    local header = self:pageHeader(full_w)
    local top = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = S(6) },
        self:buildStatusLine(full_w),
        VerticalSpan:new{ width = S(10) },
        header,
    }
    local top_h = top:getSize().h
    -- the keyboard takes the bottom of the screen while it's up
    local bottom = self.H
    if self:keyboardUp() then
        local kd = self.input:getKeyboardDimen()
        if kd and kd.h and kd.h > 0 then bottom = self.H - kd.h end
    end
    local footer_h = self:keyboardUp() and 0 or self.footer_h
    local avail_h = math.max(self.row_h, bottom - top_h - footer_h - S(6))
    local elements
    if lvl.kind == "search" then elements = self:searchElements(self:innerWidth())
    elseif lvl.build then elements = lvl.build()
    else elements = self:itemElements(lvl.items, self:innerWidth()) end
    local pages = self:paginate(elements, avail_h)
    self.page_count = #pages
    if lvl.target_item and not lvl.target_paged then
        lvl.target_paged = true
        for pi, pg in ipairs(pages) do
            for __, el in ipairs(pg) do
                if el.item == lvl.target_item then lvl.page = pi end
            end
        end
    end
    lvl.page = math.max(1, math.min(lvl.page or 1, #pages))

    local body = self:buildBody(pages[lvl.page], full_w)
    local column = VerticalGroup:new{
        align = "left",
        top,
        TopContainer:new{ dimen = Geom:new{ w = full_w, h = avail_h }, body },
    }
    if footer_h > 0 then table.insert(column, self:buildFooter(lvl.page, #pages, full_w)) end
    self[1] = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0, background = WHITE,
        width = self.W, height = self.H,
        HorizontalGroup:new{ HorizontalSpan:new{ width = self.margin }, column },
    }
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function HubScreen:onCloseWidget()
    if self._typed then UIManager:unschedule(self._typed) end
    pcall(function() self:hideKeyboard(true) end)
    if self.plugin and self.plugin.screen == self then self.plugin.screen = nil end
    UIManager:setDirty(nil, "flashui")
end

function HubScreen:onShow()
    -- shown again after something closed it for a while (see closeAll): it's
    -- the plugin's screen again, and what it lists may have changed
    if self.plugin and self.plugin.screen ~= self then
        local other = self.plugin.screen
        self.plugin.screen = self
        if other then pcall(function() UIManager:close(other) end) end
        pcall(function()
            local lvl = self.stack and self.stack[#self.stack]
            if lvl and lvl.rebuild then
                local ok, items = pcall(lvl.rebuild)
                if ok and type(items) == "table" then lvl.items = items end
            end
            self.index = nil
            self:render()
        end)
    end
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

return HubScreen
