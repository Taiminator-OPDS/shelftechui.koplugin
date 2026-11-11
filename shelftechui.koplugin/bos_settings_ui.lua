--[[--
The Settings app: a full-screen app with Bookshelf's chip navigation. A chip
strip of sections (ShelfTechUI, Navigation, Typesetting, …) at the top; when
you open a sub-menu, the strip becomes a breadcrumb trail ([‹] [SECTION] [Menu]
…) as Bookshelf's own drill-down does. One page per settings sub-menu. Items keep the exact semantics they have in KOReader's
pull-down menu (callbacks receive a TouchMenu-like object, `keep_menu_open`,
`checked_func`, `sub_item_table_func`, `tap_input`, ... are all honoured).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
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
local TitleBar = require("ui/widget/titlebar")
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

-- Empty box of a given size (used as a knob / spacer with a real size).
local function box(w, h)
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, VerticalSpan:new{ width = 0 } }
end

-- Bookshelf's UI font, as every ShelfTechUI surface
local UI = require("bos_ui")
local function face(size) return UI.face(size) end
local function smallface(size) return UI.face(size) end
local function italicface(size) return UI.italicFace(size) end
local function bface(size) return (UI.boldFace(size)) end
local function bflag(size) local _f, b = UI.boldFace(size) return b end

local function upper(text)
    if not require("bos_look").theme.upper then return text end
    local ok, Utf8Proc = pcall(require, "ffi/utf8proc")
    if ok and Utf8Proc.uppercase_dumb then
        local ok2, res = pcall(Utf8Proc.uppercase_dumb, text)
        if ok2 and res then return res end
    end
    return require("bos_look").case(text)
end

-- ---------------------------------------------------------------------------
-- Bookshelf-style design tokens (AndyHazz/bookshelf.koplugin): 2px black
-- outlines, small corner radius, hard down-right drop shadow, grey hairlines,
-- bold uppercase strip labels, outlined chips.
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

--- A widget on a hard black shadow (the shadow inside its size).
local OnShadow = WidgetContainer:extend{ shadow = nil }
function OnShadow:getSize()
    local s = self[1]:getSize()
    local sh = self.shadow or Look.SHADOW_SMALL
    return Geom:new{ w = s.w + sh, h = s.h + sh }
end
function OnShadow:paintTo(bb, x, y)
    local s = self[1]:getSize()
    local sh = self.shadow or Look.SHADOW_SMALL
    self.dimen = Geom:new{ x = x, y = y, w = s.w + sh, h = s.h + sh }
    Look.shadow(bb, x, y, s.w, s.h, sh)
    self[1]:paintTo(bb, x, y)
    Look.decorate(bb, x, y, s.w, s.h)
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

-- Square checkbox (bookshelf's check-square): filled with a white tick when on.
local function makeCheckbox(on, enabled)
    local d = S(26)
    local ink = enabled and BLACK or GRAY_TEXT
    local inner_d = d - 2 * LINE - S(4)
    local inner = CenterContainer:new{ dimen = Geom:new{ w = inner_d, h = inner_d },
        on and TextWidget:new{ text = "✓", face = bface(17), bold = bflag(17), fgcolor = WHITE }
           or VerticalSpan:new{ width = 0 } }
    return Card:new{
        bordersize = LINE, padding = S(2), radius = RADIUS,
        color = ink, background = on and ink or WHITE,
        inner,
    }
end

local function makeRadio(on, enabled)
    local d = S(26)
    local ink = enabled and BLACK or GRAY_TEXT
    local dot_d = S(12)
    local inner_d = d - 2 * LINE
    local dot = on and Card:new{ bordersize = 0, radius = 0,
                                 background = ink, box(dot_d, dot_d) }
                    or box(dot_d, dot_d)
    return Card:new{
        bordersize = LINE, radius = 0, color = ink, background = WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = inner_d, h = inner_d }, dot },
    }
end

-- Outlined chip (bookshelf's genre tags) for current values.
local function makeChip(text, max_w, enabled)
    local tw = TextWidget:new{
        text = upper(text), face = Look.mono(13), bold = true,
        fgcolor = enabled and BLACK or GRAY_TEXT,
        max_width = max_w - 2 * (LINE + S(10)),
    }
    return Card:new{
        bordersize = LINE, radius = 0, color = enabled and BLACK or GRAY_TEXT,
        shadow = enabled and S(2) or 0,
        FrameContainer:new{ bordersize = 0, margin = 0, padding = 0,
            padding_left = S(10), padding_right = S(10), padding_top = S(2), padding_bottom = S(2),
            tw },
    }
end

-- ---------------------------------------------------------------------------
-- The screen
-- ---------------------------------------------------------------------------

local HubScreen = InputContainer:extend{
    plugin = nil,            -- the bos_settings instance (data + actions)
    covers_fullscreen = true,
    stack = nil,
}

function HubScreen:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.stack = {}
    self.margin = S(18)
    self.row_h = S(58)
    self.group_gap = S(14)
    self.footer_h = S(60)
    self.strip_h = S(44)
    self.strip_page = 1

    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        -- the whole top-left corner (the clock and the strip's close box)
        -- closes the app: a generous target, as a corner should be
        CloseCorner = { GestureRange:new{ ges = "tap",
            range = function() return Geom:new{ x = 0, y = 0, w = S(96), h = self.top_h or S(60) } end } },
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

    self.sections = self.plugin:getSections()
    local want = require("bos_settings_store").get("settings_section")
    local idx = 1
    for i, sec in ipairs(self.sections) do if sec.id == want then idx = i end end
    self:openSection(idx, true)
end

-- ----- navigation -----------------------------------------------------------

--- Show section `idx` (a chip): its menu, at the top level.
function HubScreen:openSection(idx, quiet)
    local sec = self.sections[idx]
    if not sec then return end
    self.section_idx = idx
    require("bos_settings_store").set("settings_section", sec.id)
    self.stack = { { kind = "list", title = sec.name, items = sec.items, page = 1 } }
    self.strip_page = nil -- recomputed to show the selected chip
    self.rail_page = nil  -- the rail pages to show the open section
    if not quiet then self:render() else self:render() end
end

function HubScreen:push(level)
    level.page = level.page or 1
    table.insert(self.stack, level)
    self:render()
end

function HubScreen:back(no_close)
    if #self.stack > 1 then
        table.remove(self.stack)
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

--- Back to level `depth` (1: the section's top).
function HubScreen:popTo(depth)
    while #self.stack > depth do table.remove(self.stack) end
    self:render()
end

function HubScreen:goHome() self:popTo(1) end

function HubScreen:closeAll()
    self.plugin:closeHub()
end

function HubScreen:onBack() self:back() return true end

function HubScreen:onCloseCorner()
    self:closeAll()
    return true
end

function HubScreen:onNextPage() self:gotoPage(1, true) return true end

function HubScreen:onPrevPage() self:gotoPage(-1, true) return true end

function HubScreen:onSwipe(arg, ges)
    local dir = ges.direction
    if dir == "west" then
        self:gotoPage(1, true)
        return true
    elseif dir == "east" then
        self:gotoPage(-1, true)
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

--- Open section `sec_id` at the row called `name` (its stable part: the
--- value after a colon may have changed): marked, and opened if it's a menu.
function HubScreen:openRow(sec_id, name)
    local key = require("bos_settings_away").key
    for idx, sec in ipairs(self.sections or {}) do
        if sec.id == sec_id then
            self:openSection(idx, true)
            for _j, it in ipairs(sec.items or {}) do
                if type(it) == "table" and not it.heading and not it.stui_away and key(itemText(it)) == key(name) then
                    local sub = self:subTable(it)
                    if sub and #sub > 0 then
                        self:activate(it)
                    else
                        self.stack[#self.stack].target_item = it
                        self:render()
                    end
                    return true
                end
            end
            return false
        end
    end
    return false
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

--- Open `tab` (a KOReader menu) on its section and walk the item indexes in
--- `path` (as found by menu search): intermediate indexes open sub-pages,
--- the last one is shown highlighted.
function HubScreen:openPath(tab, path)
    local idx
    for i, sec in ipairs(self.sections) do
        if sec.items == tab then idx = i end
        for _j, t in ipairs(sec.tabs or {}) do if t == tab then idx = i end end
    end
    if idx then
        self.section_idx = idx
        self.stack = { { kind = "list", title = self.sections[idx].name, items = tab, page = 1 } }
    else
        self.stack = { { kind = "list", title = self.plugin:tabName(tab), items = tab, page = 1 } }
    end
    self.strip_page = nil
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

function HubScreen:gapBefore(prev, el)
    if not prev then return 0 end
    if el.kind == "label" then return S(16) end
    if prev.kind == "label" then return S(2) end
    if el.kind == "row" and prev.kind == "row" and el.group == prev.group then
        return Size.line.medium
    end
    return self.group_gap
end

function HubScreen:elementHeight(el)
    if el.kind == "row" then return el.spec.h or self.row_h end
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
            need = self:elementHeight(el)
        end
        table.insert(cur, el)
        used = used + need
    end
    if #cur > 0 or #pages == 0 then table.insert(pages, cur) end
    return pages
end

-- The right-hand side of a row: [chip] [checkbox | radio | › | custom]
function HubScreen:rightGroup(spec, w)
    local enabled = spec.enabled ~= false
    local right_group = HorizontalGroup:new{ align = "center" }
    if spec.right_widget then
        table.insert(right_group, spec.right_widget)
        if spec.checkable or spec.has_sub then table.insert(right_group, HorizontalSpan:new{ width = S(10) }) end
    end
    if spec.value then
        table.insert(right_group, makeChip(tostring(spec.value), math.floor(w * 0.4), enabled))
        if spec.checkable or spec.has_sub then
            table.insert(right_group, HorizontalSpan:new{ width = S(10) })
        end
    end
    if spec.checkable then
        table.insert(right_group, spec.radio and makeRadio(spec.checked, enabled)
                                              or makeCheckbox(spec.checked, enabled))
    elseif spec.has_sub then
        table.insert(right_group, IconWidget:new{ icon = "chevron.right", width = S(22), height = S(22) })
    end
    return right_group
end

function HubScreen:textWidth(spec, w)
    local right_w = self:rightGroup(spec, w):getSize().w
    return w - 2 * S(6) - right_w - (right_w > 0 and S(12) or 0)
end

--- A row's height: one line, or more with its description.
function HubScreen:rowHeight(spec, w)
    if not spec.description then return self.row_h end
    local tb = TextBoxWidget:new{ text = spec.description, face = face(15), width = self:textWidth(spec, w) }
    local dh = tb:getSize().h
    tb:free()
    return math.max(self.row_h, S(14) + S(28) + dh + S(12))
end

-- A list row: title (with its description under it) ........ [chip|checkbox|›]
function HubScreen:makeRow(spec, w)
    local h = spec.h or self.row_h
    local pad = S(6)
    local enabled = spec.enabled ~= false
    local right_group = self:rightGroup(spec, w)
    local text_max = self:textWidth(spec, w)
    local text_w = TextWidget:new{
        text = spec.text, face = face(20), max_width = text_max,
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
    local dim = Geom:new{ w = w, h = h }
    local content = OverlapGroup:new{
        dimen = dim:copy(),
        LeftContainer:new{ dimen = dim:copy(),
            HorizontalGroup:new{ HorizontalSpan:new{ width = pad }, left } },
        RightContainer:new{ dimen = dim:copy(),
            HorizontalGroup:new{ right_group, HorizontalSpan:new{ width = pad } } },
    }
    return Tappable:new{
        width = w, height = h,
        enabled = enabled,
        callback = spec.callback,
        hold_callback = spec.hold_callback,
        content,
    }
end

-- A group of rows: flat list with grey hairlines between rows (bookshelf list view).
function HubScreen:makeCard(rows, card_w)
    local vg = VerticalGroup:new{ align = "left" }
    for i, spec in ipairs(rows) do
        if i > 1 then
            table.insert(vg, LineWidget:new{ dimen = Geom:new{ w = card_w, h = Size.line.medium },
                                             background = HAIRLINE })
        end
        table.insert(vg, self:makeRow(spec, card_w))
    end
    return vg
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
        local gap = self:gapBefore(prev, el)
        if el.kind == "row" then
            if prev and prev.kind == "row" and prev.group == el.group then
                -- same group
            else
                flush()
                if gap > 0 then table.insert(body, VerticalSpan:new{ width = gap }) end
                if prev and prev.kind == "row" then
                    -- a new group starts: a solid rule, as between bookshelf sections
                    table.insert(body, LineWidget:new{ dimen = Geom:new{ w = avail_w, h = Size.line.medium },
                                                       background = GRAY_TEXT })
                end
            end
            table.insert(card_rows, self:liveSpec(el))
        else
            flush()
            if gap > 0 then table.insert(body, VerticalSpan:new{ width = gap }) end
            if el.kind == "label" then
                table.insert(body, Heading:new{ width = avail_w, text = el.text })
            end
        end
        prev = el
    end
    flush()
    return body
end

-- ----- chrome: status line, chip strip / breadcrumbs, footer ------------------

local function clockText()
    local ok, datetime = pcall(require, "datetime")
    if ok and datetime.secondsToHour then
        return datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    end
    return os.date("%H:%M")
end

local function batteryText()
    local ok, txt = pcall(function()
        local powerd = Device:getPowerDevice()
        if Device:hasBattery() then return powerd:getCapacity() .. "%" end
    end)
    return ok and txt or nil
end

-- Bookshelf's status line: the same one as on the shelf, in Quick Settings
-- and on the reading toolbar.
function HubScreen:buildStatusLine(w)
    local row = UI.buildStatusRow(w)
    if row then return row end
    local h = S(34)
    local right = clockText()
    local batt = batteryText()
    if batt then right = right .. "   " .. batt end
    return VerticalGroup:new{
        align = "left",
        RightContainer:new{ dimen = Geom:new{ w = w, h = h },
            TextWidget:new{ text = right, face = smallface(17) } },
        LineWidget:new{ dimen = Geom:new{ w = w, h = Size.line.medium }, background = GRAY_TEXT },
    }
end

local CHIP_FONT = 16

-- One segmented strip (Bookshelf's chip bar): thin outline, thin separators,
-- bold capitals; the selected cell filled black.
-- cells: { { text = | icon =, width = (fixed) | nil (shares the rest), selected, callback } }
function HubScreen:strip(cells, w)
    local h = self.strip_h
    local b = Size.border.default
    local inner_w = w - 2 * b
    local fixed, n_flex, nat = 0, 0, {}
    local f, bold = Look.mono(CHIP_FONT - 3), true
    b = LINE
    inner_w = w - Look.SHADOW_SMALL - 2 * b
    for i, c in ipairs(cells) do
        if c.width then fixed = fixed + c.width
        else
            n_flex = n_flex + 1
            local tw = TextWidget:new{ text = upper(c.text), face = f, bold = bold }
            nat[i] = tw:getSize().w + 2 * S(12)
            tw:free()
        end
    end
    local seps = (#cells - 1) * b
    local flex_total = inner_w - fixed - seps
    -- equal shares when every label fits, else in proportion
    local maxnat, sumnat = 0, 0
    for _i, v in pairs(nat) do maxnat = math.max(maxnat, v); sumnat = sumnat + v end
    local equal = n_flex > 0 and maxnat * n_flex <= flex_total
    local widths, used, last = {}, 0, nil
    for i, c in ipairs(cells) do
        if c.width then widths[i] = c.width
        else
            widths[i] = equal and math.floor(flex_total / n_flex)
                or math.floor(flex_total * nat[i] / math.max(1, sumnat))
            last = i
        end
        used = used + widths[i]
    end
    if last then widths[last] = widths[last] + (inner_w - seps - used) end
    local hg = HorizontalGroup:new{}
    for i, c in ipairs(cells) do
        if i > 1 then
            table.insert(hg, LineWidget:new{ dimen = Geom:new{ w = b, h = h }, background = BLACK })
        end
        local cw = widths[i]
        local sel = c.selected
        local inner
        if c.icon then
            inner = IconWidget:new{ icon = c.icon, width = S(24), height = S(24), invert = sel, alpha = true,
                dim = c.enabled == false }
        else
            inner = TextWidget:new{ text = upper(c.text), face = f, bold = bold,
                fgcolor = sel and WHITE or (c.dim and GRAY_TEXT or BLACK), max_width = cw - S(10) }
        end
        table.insert(hg, Tappable:new{
            width = cw, height = h,
            enabled = c.enabled ~= false,
            callback = c.callback,
            FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0,
                background = sel and BLACK or WHITE,
                CenterContainer:new{ dimen = Geom:new{ w = cw, h = h }, inner },
            },
        })
    end
    return OnShadow:new{ FrameContainer:new{
        bordersize = b, margin = 0, padding = 0, color = BLACK, background = WHITE, hg,
    } }
end

--- The sections as chips, paged with ‹ › cells when they don't all fit.
function HubScreen:sectionChips(w)
    local b = Size.border.default
    local f, bold = Look.mono(CHIP_FONT - 3), true
    local chev_w = S(40)
    local nat = {}
    local total = 0
    for i, sec in ipairs(self.sections) do
        local tw = TextWidget:new{ text = upper(sec.name), face = f, bold = bold }
        nat[i] = tw:getSize().w + 2 * S(12)
        tw:free()
        total = total + nat[i] + (i > 1 and b or 0)
    end
    local inner = w - 2 * b
    local pages = {}
    if total <= inner then
        pages[1] = {}
        for i = 1, #self.sections do table.insert(pages[1], i) end
    else
        local room = inner - 2 * (chev_w + b)
        local cur, used = {}, 0
        for i = 1, #self.sections do
            local need = nat[i] + (#cur > 0 and b or 0)
            if #cur > 0 and used + need > room then
                table.insert(pages, cur)
                cur, used = {}, 0
                need = nat[i]
            end
            table.insert(cur, i)
            used = used + need
        end
        if #cur > 0 then table.insert(pages, cur) end
    end
    if not self.strip_page then
        self.strip_page = 1
        for p, list in ipairs(pages) do
            for _j, i in ipairs(list) do if i == self.section_idx then self.strip_page = p end end
        end
    end
    self.strip_page = math.max(1, math.min(#pages, self.strip_page))
    local p = self.strip_page
    local cells = {}
    local paged = #pages > 1
    if paged then
        table.insert(cells, { icon = "chevron.left", width = chev_w, enabled = p > 1,
            callback = function() self.strip_page = p - 1 self:render() end })
    end
    for _j, i in ipairs(pages[p]) do
        local sec = self.sections[i]
        table.insert(cells, { text = sec.name, selected = i == self.section_idx,
            callback = function()
                if i == self.section_idx and #self.stack == 1 then return end
                self:openSection(i)
            end })
    end
    if paged then
        table.insert(cells, { icon = "chevron.right", width = chev_w, enabled = p < #pages,
            callback = function() self.strip_page = p + 1 self:render() end })
    end
    return self:strip(cells, w)
end

--- In a sub-menu: [‹] [SECTION] [Menu] [Sub-menu] … (the current page is the
--- title below). Older crumbs give way to "…" when they don't fit.
function HubScreen:breadcrumbs(w)
    local sec = self.sections[self.section_idx]
    local depth = #self.stack
    local cells = {
        { icon = "chevron.left", width = S(44), callback = function() self:back() end },
        { text = sec and sec.name or self.stack[1].title, selected = true,
          callback = function() self:popTo(1) end },
    }
    local crumbs = {}
    for d = 2, depth - 1 do
        local dd = d
        table.insert(crumbs, { text = self.stack[d].title, callback = function() self:popTo(dd) end })
    end
    -- keep the nearest crumbs; at most two, the rest collapse into "…"
    if #crumbs > 2 then
        local keep = { { text = "…", callback = crumbs[#crumbs - 2].callback } }
        table.insert(keep, crumbs[#crumbs - 1])
        table.insert(keep, crumbs[#crumbs])
        crumbs = keep
    end
    for _i, c in ipairs(crumbs) do table.insert(cells, c) end
    return self:strip(cells, w)
end

-- Footer: ✕ close, and the page controls when there's more than one page.
function HubScreen:buildFooter(page, count, w)
    local h = self.footer_h
    w = w or (self.W - 2 * self.margin)
    -- (closing is the box in the SETTINGS strip at the top)
    if count <= 1 then return VerticalSpan:new{ width = h } end
    local cell = S(54)
    -- square retro buttons on a hard shadow (flat and grey when disabled)
    local function btn(icon, cb, enabled)
        local bw, bh = S(44), S(38)
        local face_ = Card:new{ bordersize = LINE, radius = 0, color = enabled and BLACK or GRAY_TEXT,
            shadow = enabled and Look.SHADOW_SMALL or 0,
            CenterContainer:new{ dimen = Geom:new{ w = bw - 2 * LINE, h = bh - 2 * LINE },
                IconWidget:new{ icon = icon, width = S(22), height = S(22), dim = not enabled } } }
        return Tappable:new{ width = cell, height = h, enabled = enabled, callback = cb,
            CenterContainer:new{ dimen = Geom:new{ w = cell, h = h }, face_ } }
    end
    local mid_w = w - 4 * cell
    local label = TextWidget:new{ text = string.format("%d / %d", page, count),
        face = Look.mono(16), bold = true, max_width = mid_w }
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


-- ----- the side rail: the sections as bookmarks ------------------------------

--[[ The sections run down the left edge as tabs, like bookmarks in the side of
a book: each a square tab with its icon and name, tucked in against the page's
edge (a black rule). The open one is black, sticks out further, and has a
ribbon's V-notch at its end. When they don't all fit, ▲ ▼ page the rail.
--]]
local Rail = InputContainer:extend{ width = nil, height = nil, hub = nil }

function Rail:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapRail = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        SwipeRail = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
    local hub = self.hub
    self.tab_h = S(64)
    self.gap = S(8)
    self.arrows_h = S(40)
    local n = #hub.sections
    local fit = math.max(1, math.floor((self.height + self.gap) / (self.tab_h + self.gap)))
    if n > fit then
        fit = math.max(1, math.floor((self.height - self.arrows_h - S(6) + self.gap) / (self.tab_h + self.gap)))
    end
    self.per = fit
    self.pages = math.max(1, math.ceil(n / fit))
    if not hub.rail_page then hub.rail_page = math.ceil((hub.section_idx or 1) / fit) end
    hub.rail_page = math.max(1, math.min(self.pages, hub.rail_page))
end

function Rail:getSize() return Geom:new{ w = self.width, h = self.height } end

function Rail:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local hub = self.hub
    local w, h = self.width, self.height
    bb:paintRect(x, y, w, h, WHITE)
    -- the page's edge
    local edge = x + w - LINE
    bb:paintRect(edge, y, LINE, h, BLACK)
    self.hits = {}
    local first = (hub.rail_page - 1) * self.per + 1
    local last = math.min(#hub.sections, first + self.per - 1)
    local ty = y
    for i = first, last do
        local sec = hub.sections[i]
        local sel = i == hub.section_idx
        local pressed = self.pressed == i
        local tuck = sel and 0 or S(14)          -- the open tab sticks out further
        local tx = x + tuck
        local tw = edge - tx + (sel and LINE or 0) -- the open one runs into the page
        local th = self.tab_h
        if sel then
            -- the bookmark: black, a hard shadow, a V-notch at its end
            bb:paintRect(tx + Look.SHADOW_SMALL, ty + Look.SHADOW_SMALL, tw - Look.SHADOW_SMALL, th, BLACK)
            bb:paintRect(tx, ty, tw, th, BLACK)
            local notch = S(9)
            local half = math.floor(th / 2)
            for k = 0, notch - 1 do
                local span = math.floor(half * (notch - k) / notch)
                bb:paintRect(tx + k, ty, 1, span, WHITE)
                bb:paintRect(tx + k, ty + th - span, 1, span, WHITE)
            end
        else
            Look.box(bb, tx, ty, tw + LINE, th, { fill = pressed and BLACK or WHITE })
        end
        local ink_white = sel or pressed
        local ink = ink_white and WHITE or BLACK
        local cx0 = tx + (sel and S(10) or 0)
        local cw = edge - cx0
        local isz = S(22)
        if sec.icon then
            pcall(UI.paintIcon, bb, sec.icon, cx0 + math.floor((cw - isz) / 2), ty + S(8), isz, ink_white)
        end
        Look.label(bb, sec.name, cx0 + S(4), ty + S(34), cw - S(8), S(24), 10, { align = "center", color = ink })
        table.insert(self.hits, { rect = Geom:new{ x = x, y = ty, w = w, h = th }, idx = i })
        ty = ty + th + self.gap
    end
    -- ▲ ▼ when the sections don't all fit
    self.up_rect, self.down_rect = nil, nil
    if self.pages > 1 then
        local bw = math.floor((edge - x - S(10) - Look.SHADOW_SMALL) / 2)
        local by = y + h - self.arrows_h
        self.up_rect = Look.button(bb, x, by, bw, self.arrows_h - Look.SHADOW_SMALL, "\u{25B2}",
            { enabled = hub.rail_page > 1, size = 12 })
        self.down_rect = Look.button(bb, x + bw + S(8), by, bw, self.arrows_h - Look.SHADOW_SMALL, "\u{25BC}",
            { enabled = hub.rail_page < self.pages, size = 12 })
    end
end

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function Rail:onTapRail(_, ges)
    local hub = self.hub
    if inside(ges.pos, self.up_rect) then
        if hub.rail_page > 1 then hub.rail_page = hub.rail_page - 1 hub:render() end
        return true
    end
    if inside(ges.pos, self.down_rect) then
        if hub.rail_page < self.pages then hub.rail_page = hub.rail_page + 1 hub:render() end
        return true
    end
    for _i, hit in ipairs(self.hits or {}) do
        if inside(ges.pos, hit.rect) then
            if hit.idx == hub.section_idx and #hub.stack == 1 then return true end
            -- pressed for a moment, then the section opens
            self.pressed = hit.idx
            UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
            UIManager:setDirty(nil, "fast", self.dimen)
            UIManager:forceRePaint()
            self.pressed = nil
            hub:openSection(hit.idx)
            return true
        end
    end
    return true
end

function Rail:onSwipeRail(_, ges)
    local hub = self.hub
    if ges.direction == "north" and hub.rail_page < self.pages then hub.rail_page = hub.rail_page + 1 hub:render()
    elseif ges.direction == "south" and hub.rail_page > 1 then hub.rail_page = hub.rail_page - 1 hub:render() end
    return true
end

--- Above the page: on a sub-page, [‹] and the way here (SECTION › Menu);
--- then the page's name.
function HubScreen:pageHeader(w)
    local vg = VerticalGroup:new{ align = "left" }
    local depth = #self.stack
    local lvl = self.stack[depth]
    local sec = self.sections[self.section_idx]
    -- a section's own page: the black tab already names it
    if depth == 1 then return VerticalSpan:new{ width = 0 } end
    if depth > 1 then
        local trail = { sec and sec.name or "" }
        for d = 2, depth - 1 do table.insert(trail, self.stack[d].title or "") end
        local bh = S(34)
        local back_btn = Tappable:new{
            width = bh + Look.SHADOW_SMALL, height = bh + Look.SHADOW_SMALL,
            callback = function() self:back() end,
            Card:new{ bordersize = LINE, radius = 0, shadow = Look.SHADOW_SMALL,
                CenterContainer:new{ dimen = Geom:new{ w = bh - 2 * LINE, h = bh - 2 * LINE },
                    IconWidget:new{ icon = "chevron.left", width = S(20), height = S(20) } } },
        }
        local trail_w = TextWidget:new{ text = upper(table.concat(trail, "  \u{203A}  ")),
            face = Look.mono(11), bold = true, fgcolor = GRAY_TEXT, max_width = w - bh - S(20) }
        table.insert(vg, HorizontalGroup:new{ align = "center",
            back_btn, HorizontalSpan:new{ width = S(12) },
            Tappable:new{ width = trail_w:getSize().w, height = bh, callback = function() self:popTo(1) end,
                CenterContainer:new{ dimen = Geom:new{ w = trail_w:getSize().w, h = bh }, trail_w } } })
        table.insert(vg, VerticalSpan:new{ width = S(8) })
    end
    table.insert(vg, TextWidget:new{ text = lvl.title or (sec and sec.name) or "", face = bface(22),
        bold = bflag(22), max_width = w })
    table.insert(vg, VerticalSpan:new{ width = S(4) })
    table.insert(vg, LineWidget:new{ dimen = Geom:new{ w = w, h = LINE }, background = BLACK })
    table.insert(vg, VerticalSpan:new{ width = S(4) })
    return vg
end

function HubScreen:render()
    local lvl = self.stack[#self.stack]
    local full_w = self.W - 2 * self.margin
    -- status line; the pinstriped SETTINGS strip (its box closes the app)
    local Retro = require("bos_retro")
    local top = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = S(6) },
        self:buildStatusLine(full_w),
        VerticalSpan:new{ width = S(6) },
        Retro.TitleStrip:new{ width = full_w, height = S(34), caption = _("Settings"), size = 14,
            close_callback = function() self:closeAll() end },
        VerticalSpan:new{ width = S(12) },
    }
    local top_h = top:getSize().h
    self.top_h = top_h - S(10) -- (not the space under the strip: the rail starts there)
    -- the rail on the left, the page on the right
    local rail_w = math.min(S(118), math.floor(full_w * 0.27))
    local gap = S(14)
    local avail_w = full_w - rail_w - gap
    local below_h = self.H - top_h - S(8)
    local header = self:pageHeader(avail_w)
    local avail_h = below_h - header:getSize().h - self.footer_h
    local elements = lvl.build and lvl.build() or self:itemElements(lvl.items, avail_w)
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

    local body = self:buildBody(pages[lvl.page], avail_w)
    local page_col = VerticalGroup:new{
        align = "left",
        header,
        TopContainer:new{ dimen = Geom:new{ w = avail_w, h = avail_h }, body },
        self:buildFooter(lvl.page, #pages, avail_w),
    }
    local rail = Rail:new{ width = rail_w, height = below_h - S(4), hub = self }
    local column = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{ HorizontalSpan:new{ width = self.margin }, top },
        HorizontalGroup:new{ align = "top",
            HorizontalSpan:new{ width = self.margin }, rail, HorizontalSpan:new{ width = gap }, page_col },
    }
    self[1] = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0, background = WHITE,
        width = self.W, height = self.H,
        column,
    }
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function HubScreen:onCloseWidget()
    if self.plugin and self.plugin.screen == self then self.plugin.screen = nil end
    UIManager:setDirty(nil, "flashui")
end

function HubScreen:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

return HubScreen
