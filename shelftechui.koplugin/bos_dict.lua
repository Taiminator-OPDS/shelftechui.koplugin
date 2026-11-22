--[[
The dictionary window, modernised: rounded, the word big at the top, the
definition without a frame, and a row of rounded keys at the bottom.

    ╭─────────────────────────────────────────╮
    │ lamp                               ✎  × │  the word (✎: look up another)
    │ Oxford English · 1/3 ▾                  │  tap: the other dictionaries
    │ ─────────────────────────────────────── │
    │ the definition, scrolling               │
    │ ─────────────────────────────────────── │
    │ (Dicts ▾) (Dict|Wiki) (X-Ray) (Highlight)│
    ╰─────────────────────────────────────────╯

  * Dicts ▾ (and the dictionary's name) pops a menu up: every dictionary with
    a result (the one shown, filled), then everything else the window can do
    (Search, Translate, Vocabulary builder, plugins' buttons…).
  * Dict | Wiki: the dictionaries or Wikipedia. Highlight keeps the word
    highlighted. X-Ray: the book's people and places (bos_xray), on the word's
    entry when it's one of them; with none downloaded yet, it asks to.

KOReader's DictQuickLookup does all the work; this only re-lays its window
out. Its own widgets (title bar, buttons) stay alive off screen, so all of its
methods keep working.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local UI = require("bos_ui")
local S = UI.S
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_DARK_GRAY

local M = {}
local switchDomain

local function Size1() return math.max(1, S(1)) end

M.STYLE = {
    border  = S(1.5), -- the window's outline
    radius  = S(14),  -- its corners
    shadow  = S(5),   -- its shadow (as the theme draws shadows)
    head_h  = S(76),
    bar_h   = S(56),
    margin  = S(12),  -- inside the window
    edge    = S(10),  -- from the screen's edges
}
local ST = M.STYLE

local function mono(size, bold)
    return require("bos_look").mono(size), bold
end

--- Text in the retro face, drawn into bb; returns its width.
local function drawText(bb, text, x, y, w, h, opts)
    opts = opts or {}
    local tw = TextWidget:new{
        text = text, face = (mono(opts.size or 14)), bold = opts.bold ~= false,
        fgcolor = opts.color or BLACK, max_width = w,
    }
    local sz = tw:getSize()
    local tx = x
    if opts.align == "center" then tx = x + math.floor((w - sz.w) / 2)
    elseif opts.align == "right" then tx = x + w - sz.w end
    tw:paintTo(bb, tx, y + math.floor((h - sz.h) / 2))
    tw:free()
    return sz.w
end

local function textWidth(text, size, bold)
    local tw = TextWidget:new{ text = text, face = (mono(size)), bold = bold ~= false }
    local w = tw:getSize().w
    tw:free()
    return w
end

--- A retro box: outline, fill, and a hard shadow (none when pressed).
local function box(bb, x, y, w, h, opts)
    opts = opts or {}
    local b = opts.border or ST.border
    local sh = opts.shadow or 0
    require("bos_look").box(bb, x, y, w, h, { border = b, shadow = sh, color = opts.color, fill = opts.fill })
end

-- ---------------------------------------------------------------------------
-- A painted, tappable area
-- ---------------------------------------------------------------------------

local Painted = InputContainer:extend{
    width = 0, height = 0,
    draw = nil,          -- fn(self, bb, x, y)
    tap = nil,           -- fn(self, pos) -> bool
    hold = nil,          -- fn(self, pos) -> bool
}

function Painted:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local range = function() return self.dimen end
    self.ges_events = {
        TapPainted = { GestureRange:new{ ges = "tap", range = range } },
        HoldPainted = { GestureRange:new{ ges = "hold", range = range } },
    }
end

function Painted:getSize() return Geom:new{ w = self.width, h = self.height } end

function Painted:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.dimen.w, self.dimen.h = self.width, self.height
    if self.draw then self:draw(bb, x, y) end
end

function Painted:onTapPainted(_, ges)
    if self.tap then return self:tap(ges.pos) and true or false end
    return false
end

function Painted:onHoldPainted(_, ges)
    if self.hold then return self:hold(ges.pos) and true or false end
    return false
end

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function Painted:repaint()
    if not self.dimen.x then return end
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, "fast", self.dimen)
end

-- ---------------------------------------------------------------------------
-- The start menu
-- ---------------------------------------------------------------------------

local StartMenu = InputContainer:extend{
    name = "bookshelfos_dict_startmenu",
    anchor = nil,        -- Geom of the start button
    band_text = nil,     -- the vertical band's label
    sections = nil,      -- { { rows = { { text, selected, enabled, callback } } } }
    modal = true,
    covers_footer = true,
}

function StartMenu:init()
    self.row_h = S(40)
    self.band_w = S(30)
    self.pad = S(12)
    self.size = 15
    local text_w = 0
    for _i, sec in ipairs(self.sections) do
        for _j, r in ipairs(sec.rows) do
            text_w = math.max(text_w, textWidth(r.text, self.size, r.selected))
        end
    end
    local max_w = Screen:getWidth() - 2 * ST.edge - ST.shadow
    self.w = math.min(max_w, self.band_w + 2 * self.pad + S(22) + text_w + 2 * ST.border)
    self.w = math.max(self.w, S(200))
    -- pages, if it doesn't all fit above the button
    local avail = (self.anchor and self.anchor.y or Screen:getHeight()) - ST.edge - 2 * ST.border - ST.shadow
    local per_page = math.max(3, math.floor(avail / self.row_h) - 1)
    local flat = {}
    for si, sec in ipairs(self.sections) do
        if si > 1 and #sec.rows > 0 and #flat > 0 then table.insert(flat, { sep = true }) end
        for _j, r in ipairs(sec.rows) do table.insert(flat, r) end
    end
    self.pages = {}
    local page = {}
    for _i, r in ipairs(flat) do
        if #page >= per_page then
            table.insert(self.pages, page)
            page = {}
        end
        if not (r.sep and #page == 0) then table.insert(page, r) end
    end
    if #page > 0 then table.insert(self.pages, page) end
    if #self.pages > 1 then
        for i, p in ipairs(self.pages) do
            table.insert(p, { more = true, text = i < #self.pages and _("More ▾") or _("Back to the top ▴") })
        end
    end
    self.page = 1
    self:layout()
    local range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapMenu = { GestureRange:new{ ges = "tap", range = range } },
        HoldMenu = { GestureRange:new{ ges = "hold", range = range } },
        SwipeMenu = { GestureRange:new{ ges = "swipe", range = range } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function StartMenu:rowHeight(r) return r.sep and S(10) or self.row_h end

function StartMenu:layout()
    local rows = self.pages[self.page] or {}
    local h = 2 * ST.border
    for _i, r in ipairs(rows) do h = h + self:rowHeight(r) end
    self.h = h
    local ax = self.anchor and self.anchor.x or ST.edge
    local ay = self.anchor and self.anchor.y or Screen:getHeight() - ST.edge
    local x = math.max(ST.edge, math.min(ax, Screen:getWidth() - ST.edge - ST.shadow - self.w))
    local y = ay - S(4) - h
    if y < ST.edge then
        -- no room above: open downwards from the button
        y = (self.anchor and (self.anchor.y + self.anchor.h + S(4))) or ST.edge
    end
    self.rect = Geom:new{ x = x, y = y, w = self.w, h = h }
    self.dimen = Geom:new{ x = x, y = y, w = self.w + ST.shadow, h = h + ST.shadow }
end

function StartMenu:paintTo(bb)
    local r = self.rect
    box(bb, r.x, r.y, r.w, r.h, { shadow = ST.shadow })
    local b = ST.border
    -- the band, its label reading upwards
    local bx, by, bh = r.x + b, r.y + b, r.h - 2 * b
    bb:paintRect(bx, by, self.band_w, bh, BLACK)
    pcall(function()
        local label = self.band_text or _("Dictionaries")
        local tw = TextWidget:new{ text = label, face = (mono(16)), bold = true, fgcolor = WHITE,
            max_width = bh - S(16) }
        local sz = tw:getSize()
        local tmp = Blitbuffer.new(sz.w, sz.h, bb:getType())
        tmp:fill(BLACK)
        tw:paintTo(tmp, 0, 0)
        tw:free()
        local rot = tmp:rotatedCopy(270)
        tmp:free()
        local rw, rh = rot:getWidth(), rot:getHeight()
        bb:blitFrom(rot, bx + math.floor((self.band_w - rw) / 2), by + bh - S(10) - rh, 0, 0, rw, rh)
        rot:free()
    end)
    -- rows
    local x0 = bx + self.band_w
    local w = r.w - 2 * b - self.band_w
    local y = by
    self.row_rects = {}
    for _i, row in ipairs(self.pages[self.page] or {}) do
        local rh = self:rowHeight(row)
        if row.sep then
            bb:paintRect(x0 + S(8), y + math.floor(rh / 2) - 1, w - S(16), Size1(), BLACK)
            bb:paintRect(x0 + S(8), y + math.floor(rh / 2) + 1, w - S(16), Size1(), BLACK)
        else
            local sel = row.selected or self.pressed == row
            if sel then bb:paintRect(x0, y, w, rh, BLACK) end
            local ink = sel and WHITE or ((row.enabled == false) and GRAY or BLACK)
            local mark = row.more and "" or (row.selected and "\u{25B8}" or (row.check and "\u{2713}" or ""))
            drawText(bb, mark, x0 + S(6), y, S(16), rh, { size = self.size, color = ink })
            drawText(bb, row.text, x0 + S(24), y, w - S(30), rh,
                { size = self.size, color = ink, bold = row.selected or row.more or false })
            table.insert(self.row_rects, { row = row, rect = Geom:new{ x = x0, y = y, w = w, h = rh } })
        end
        y = y + rh
    end
end

function StartMenu:rowAt(pos)
    for _i, rr in ipairs(self.row_rects or {}) do
        if inside(pos, rr.rect) then return rr.row end
    end
end

function StartMenu:onTapMenu(_, ges)
    if not inside(ges.pos, self.rect) then
        self:onClose()
        return true
    end
    local row = self:rowAt(ges.pos)
    if not row or row.enabled == false then return true end
    if row.more then
        self.page = self.page % #self.pages + 1
        local old = self.dimen
        self:layout()
        UIManager:setDirty(self.parent_dql, "ui", old)
        UIManager:setDirty(self, "ui", self.dimen)
        return true
    end
    self.pressed = row
    UIManager:widgetRepaint(self, 0, 0)
    UIManager:setDirty(nil, "fast", self.rect)
    UIManager:forceRePaint()
    self.pressed = nil
    self:onClose()
    if row.callback then
        -- (after the tap is over: some actions show a dismissable box)
        UIManager:scheduleIn(row.delay and 0.3 or 0, function()
            local ok, err = pcall(row.callback)
            if not ok then logger.warn("ShelfTechUI: dictionary menu:", err) end
        end)
    end
    return true
end

function StartMenu:onHoldMenu(_, ges)
    local row = inside(ges.pos, self.rect) and self:rowAt(ges.pos)
    if row and row.hold_callback then
        self:onClose()
        UIManager:nextTick(row.hold_callback)
    end
    return true
end

function StartMenu:onSwipeMenu(_, ges)
    if #self.pages > 1 and inside(ges.pos, self.rect) and (ges.direction == "north" or ges.direction == "south") then
        local d = ges.direction == "north" and 1 or -1
        self.page = (self.page - 1 + d) % #self.pages + 1
        local old = self.dimen
        self:layout()
        UIManager:setDirty(self.parent_dql, "ui", old)
        UIManager:setDirty(self, "ui", self.dimen)
        return true
    end
    self:onClose()
    return true
end

function StartMenu:onClose()
    UIManager:close(self, "ui", self.dimen)
    if self.parent_dql and self.parent_dql.menu_opened then self.parent_dql.menu_opened[self] = nil end
    if self.on_close then self.on_close() end
    return true
end

function StartMenu:onShow()
    UIManager:setDirty(self, "ui", self.dimen)
    return true
end

M.StartMenu = StartMenu

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local SKIP_IN_MENU = { prev_dict = true, next_dict = true, close = true, highlight = true }

--- The window's other actions, from its (hidden) button table.
local function actionRows(dql)
    local rows = {}
    local bt = dql.button_table
    if not bt then return rows end
    for _i, row in ipairs(bt.buttons or {}) do
        for _j, spec in ipairs(row) do
            local id = spec.id
            local skip = SKIP_IN_MENU[id] or (id == "wikipedia" and not dql.is_wiki)
            if not skip and (spec.callback or spec.text or spec.text_func) then
                local btn = id and bt:getButtonById(id)
                local text = spec.text_func and spec.text_func() or spec.text
                if btn and btn.text then text = btn.text end
                if type(text) == "string" and text ~= "" then
                    table.insert(rows, {
                        text = (text:gsub("\n", " ")),
                        delay = true,
                        enabled = not (btn and btn.enabled == false) and spec.enabled ~= false,
                        callback = function()
                            if btn and btn.callback then btn.callback()
                            elseif spec.callback then spec.callback() end
                        end,
                        hold_callback = (btn and btn.hold_callback) or spec.hold_callback,
                    })
                end
            end
        end
    end
    return rows
end

local function dictRows(dql)
    local rows = {}
    for i, res in ipairs(dql.results or {}) do
        local name = res.dict or res.lang or tostring(i)
        if dql.is_wiki and res.lang then name = "Wikipedia " .. res.lang:upper() end
        table.insert(rows, {
            text = name,
            selected = i == dql.dict_index,
            callback = function()
                if i ~= dql.dict_index then dql:changeDictionary(i) end
            end,
        })
    end
    return rows
end

function M.openStartMenu(dql, anchor)
    local sections = {
        { rows = dictRows(dql) },
        { rows = actionRows(dql) },
    }
    local menu = StartMenu:new{
        anchor = anchor,
        sections = sections,
        band_text = dql.is_wiki and _("Wikipedia") or _("Dictionaries"),
        parent_dql = dql,
        on_close = function()
            if dql._bos_start then
                dql._bos_start.open = false
                dql._bos_start:repaint()
            end
        end,
    }
    if dql.menu_opened then dql.menu_opened[menu] = true end
    if dql._bos_start then
        dql._bos_start.open = true
        dql._bos_start:repaint()
    end
    UIManager:show(menu)
    return menu
end

-- ----- pieces of the window --------------------------------------------------

--- Text in the theme's reading-UI face (as written, not in capitals); returns
--- its width (bb nil: only measures).
local function uiText(bb, text, x, y, w, h, opts)
    opts = opts or {}
    local Look = require("bos_look")
    local size = opts.size or 14
    local face = opts.serif and Look.serif(size, opts.bold) or Look.text(size, opts.bold) or Font:getFace("cfont", size)
    local tw = TextWidget:new{ text = text, face = face, bold = opts.bold and not opts.serif or false,
        fgcolor = opts.color or BLACK, max_width = math.max(1, w), truncate_with_ellipsis = true }
    local sz = tw:getSize()
    local tx = x
    if opts.align == "center" then tx = x + math.floor((w - sz.w) / 2)
    elseif opts.align == "right" then tx = x + w - sz.w end
    if bb then tw:paintTo(bb, tx, y + math.floor((h - sz.h) / 2)) end
    tw:free()
    return sz.w
end

local function glyph(bb, g, x, y, w, h, px, color)
    local t = TextWidget:new{ text = g, face = UI.symbolFace(UI.ptForPx(px)), fgcolor = color or BLACK }
    local sz = t:getSize()
    t:paintTo(bb, x + math.floor((w - sz.w) / 2), y + math.floor((h - sz.h) / 2))
    t:free()
end

--- The head: the word, big; under it the dictionary and the count (tap: the
--- other dictionaries); ✎ (look up another) and × at the right.
local function header(dql, w)
    local h = ST.head_h
    local key = S(42)
    return Painted:new{
        width = w, height = h,
        draw = function(self, bb, x, y)
            bb:paintRect(x, y, w, h, WHITE)
            local m = ST.margin + S(4)
            local right = x + w - S(6)
            self.close_rect = Geom:new{ x = right - key, y = y, w = key, h = S(50) }
            uiText(bb, "\u{00D7}", right - key, y + S(6), key, S(38), { size = 26, align = "center" })
            right = right - key
            self.edit_rect = Geom:new{ x = right - key, y = y, w = key, h = S(50) }
            glyph(bb, UI.GLYPH.pencil, right - key, y + S(6), key, S(38), S(17))
            right = right - key - S(4)
            uiText(bb, dql.displayword or dql.word or "", x + m, y + S(8), right - x - m, S(38),
                { serif = true, bold = true, size = 22 })
            local line = dql.displaydictname or ""
            if dql.displaynb and dql.displaynb ~= "" then line = line .. "  \u{00B7}  " .. dql.displaynb end
            local lw = uiText(bb, line .. "  \u{25BE}", x + m, y + S(46), w - 2 * m - S(10), S(22), { size = 12, color = GRAY })
            self.name_rect = Geom:new{ x = x + m - S(6), y = y + S(42), w = lw + S(16), h = S(30) }
        end,
        tap = function(self, pos)
            if inside(pos, self.close_rect) then dql:onClose() return true end
            if inside(pos, self.edit_rect) then dql:onLookupInputWord(dql.word) return true end
            if inside(pos, self.name_rect) then M.openStartMenu(dql, self.name_rect) return true end
            return false
        end,
        hold = function(self, pos)
            if inside(pos, self.close_rect) then dql:onHoldClose() return true end
            if inside(pos, self.edit_rect) then dql:onLookupInputWord(dql.lookupword) return true end
            -- hold the name: make this dictionary the preferred one (as KOReader)
            if inside(pos, self.name_rect) and not dql.is_wiki and dql.ui then
                dql.ui:handleEvent(Event:new("TogglePreferredDict", dql.dictionary))
                dql:changeDictionary(dql.dict_index)
                return true
            end
        end,
    }
end

--- Dictionary <-> Wikipedia for the word. Delayed like KOReader's own
--- Wikipedia button: the lookup shows a dismissable "Searching…" box, and the
--- rest of the tap that started it (its release) would otherwise land on that
--- box and cancel the search straight away.
switchDomain = function(dql)
    local word = dql.is_wiki and (dql.word or dql.lookupword) or dql.word or dql.lookupword
    UIManager:scheduleIn(0.3, function()
        local ok, err = pcall(dql.lookupDictionaryOrWikipedia, dql, word, true)
        if not ok then logger.warn("ShelfTechUI: dictionary/Wikipedia switch failed:", err) end
    end)
end

function M.toggleHighlight(dql)
    local hl = dql.highlight
    local ui = dql.ui
    if not (hl and ui and ui.annotation) then return end
    if dql._bos_hl_item then
        local annotations = ui.annotation.annotations or {}
        for i, it in ipairs(annotations) do
            if it == dql._bos_hl_item then
                pcall(hl.deleteHighlight, hl, i)
                break
            end
        end
        dql._bos_hl_item = nil
    else
        if not hl.selected_text and hl.hold_pos then pcall(hl.highlightFromHoldPos, hl) end
        local ok, index = pcall(hl.saveHighlight, hl)
        if ok and index then
            dql._bos_hl_item = ui.annotation.annotations[index]
        else
            logger.warn("ShelfTechUI: dictionary highlight failed:", index)
            UIManager:show(require("ui/widget/notification"):new{ text = _("Couldn't highlight this word") })
            return
        end
    end
    -- (KOReader's own button would save it again on close)
    dql.save_highlight = false
    -- show it on the page under the window
    UIManager:setDirty(ui.dialog or ui, "ui")
end

--- X-Ray for the book that's open, on the looked-up word when it's one of
--- its names (and asking to download it when there's none yet).
local function openXray(dql)
    local ui = dql.ui
    if not (ui and ui.document) then return end
    local word = dql.word or dql.lookupword
    UIManager:scheduleIn(0.15, function()
        require("bos_xray").open(ui, word, function()
            -- (a passage was chosen: the window goes too)
            pcall(dql.onClose, dql)
        end)
    end)
end

--- The chips: Dict | Wiki · X-Ray · Highlight.
local function chipCells(dql)
    local docless = dql:isDocless() or not (dql.ui and dql.ui.document)
    return {
        { text = _("Dict"), selected = function() return not dql.is_wiki end,
          callback = function() if dql.is_wiki then switchDomain(dql) end end },
        { text = _("Wiki"), selected = function() return dql.is_wiki end,
          callback = function() if not dql.is_wiki then switchDomain(dql) end end },
        { text = _("X-Ray"), enabled = not docless, selected = function() return false end,
          callback = function() openXray(dql) end },
        { text = _("Highlight"),
          label = function() return dql._bos_hl_item and _("\u{2713} Highlighted") or _("Highlight") end,
          selected = function() return dql._bos_hl_item ~= nil end,
          enabled = dql.highlight ~= nil and not dql.is_wiki and not docless,
          -- right away, not when the window closes (KOReader's way): the
          -- highlight appears on the page, and tapping again takes it off
          callback = function() M.toggleHighlight(dql) end },
    }
end

local function hair() return math.max(1, S(1.5)) end

--- A rounded key: outlined, or filled when on.
local function pill(bb, x, y, w, h, on, enabled)
    local r = math.floor(h / 2)
    if on then
        bb:paintRoundedRect(x, y, w, h, BLACK, r)
    else
        bb:paintRoundedRect(x, y, w, h, WHITE, r)
        bb:paintBorder(x, y, w, h, hair(), enabled == false and Blitbuffer.COLOR_LIGHT_GRAY or BLACK, r, true)
    end
end

--- The keys along the bottom: the dictionaries (▾: every one, and what else
--- the window can do), Dict | Wiki, X-Ray, Highlight.
local function bottomBar(dql, w)
    local h = ST.bar_h
    local ch = S(38)
    local cells = chipCells(dql)
    local gap = S(8)
    local m = ST.margin
    local size = 13
    local start_label = (dql.is_wiki and _("Wiki") or _("Dicts")) .. " \u{25BE}"
    local start_w = uiText(nil, start_label, 0, 0, w, ch, { size = size }) + S(28)
    -- Dict | Wiki share one key; X-Ray and Highlight have their own
    local rest = w - 2 * m - start_w - 3 * gap
    local seg_w = math.floor(rest * 0.40)
    local xr_w = math.floor(rest * 0.25)
    local hl_w = rest - seg_w - xr_w
    local bar = Painted:new{
        width = w, height = h,
        draw = function(self, bb, x, y)
            bb:paintRect(x, y, w, h, WHITE)
            local cy = y + math.floor((h - ch) / 2)
            self.rects = {}
            local cx = x + m
            -- the dictionaries
            local down = self.open
            pill(bb, cx, cy, start_w, ch, down)
            uiText(bb, start_label, cx, cy, start_w, ch, { size = size, align = "center", color = down and WHITE or BLACK })
            self.start_rect = Geom:new{ x = cx, y = cy, w = start_w, h = ch }
            cx = cx + start_w + gap
            -- Dict | Wiki
            local r = math.floor(ch / 2)
            bb:paintRoundedRect(cx, cy, seg_w, ch, WHITE, r)
            local half = math.floor(seg_w / 2)
            for i = 1, 2 do
                local c = cells[i]
                local sx = cx + (i - 1) * half
                local sw = i == 1 and half or (seg_w - half)
                local on = c.selected() or self.pressed == i
                if on then
                    bb:paintRoundedRect(sx, cy, sw, ch, BLACK, r)
                    -- (square where the halves meet)
                    if i == 1 then bb:paintRect(sx + sw - r, cy, r, ch, BLACK) else bb:paintRect(sx, cy, r, ch, BLACK) end
                end
                uiText(bb, c.text, sx, cy, sw, ch, { size = size, align = "center", color = on and WHITE or BLACK })
                self.rects[i] = Geom:new{ x = sx, y = cy, w = sw, h = ch }
            end
            bb:paintBorder(cx, cy, seg_w, ch, hair(), BLACK, r, true)
            cx = cx + seg_w + gap
            -- X-Ray, Highlight
            for j, cw in ipairs({ xr_w, hl_w }) do
                local k = j + 2
                local c = cells[k]
                local on = c.selected() or self.pressed == k
                local en = c.enabled ~= false
                pill(bb, cx, cy, cw, ch, on, en)
                uiText(bb, c.label and c.label() or c.text, cx + S(4), cy, cw - S(8), ch, { size = size, align = "center",
                    color = on and WHITE or (en and BLACK or GRAY) })
                self.rects[k] = Geom:new{ x = cx, y = cy, w = cw, h = ch }
                cx = cx + cw + gap
            end
        end,
        tap = function(self, pos)
            if inside(pos, self.start_rect) then
                M.openStartMenu(dql, self.start_rect)
                return true
            end
            for i, r in ipairs(self.rects or {}) do
                if inside(pos, r) then
                    local c = cells[i]
                    if c.enabled == false then return true end
                    self.pressed = i
                    self:repaint()
                    UIManager:forceRePaint()
                    self.pressed = nil
                    c.callback()
                    self:repaint()
                    return true
                end
            end
            return true
        end,
    }
    dql._bos_start = bar
    return bar
end

--- A hairline across the window.
local function rule(w)
    return Painted:new{ width = w, height = S(5), draw = function(_self, bb, x, y)
        bb:paintRect(x + ST.margin, y + S(2), w - 2 * ST.margin, math.max(1, S(1)), Blitbuffer.COLOR_GRAY_9)
    end }
end

-- ----- the re-layout ---------------------------------------------------------

--- The outer frame: the window and its hard shadow (included in its size, so
--- refreshes and "tap outside" cover the shadow too).
local Shadowed = WidgetContainer:extend{}

function Shadowed:getSize()
    local s = self[1]:getSize()
    return Geom:new{ w = s.w + ST.shadow, h = s.h + ST.shadow }
end

function Shadowed:paintTo(bb, x, y)
    local s = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = s.w + ST.shadow, h = s.h + ST.shadow }
    local Look = require("bos_look")
    Look.shadow(bb, x, y, s.w, s.h, ST.shadow)
    self[1]:paintTo(bb, x, y)
    Look.decorate(bb, x, y, s.w, s.h)
end

function M.restyle(dql)
    local W = dql.width
    local b = ST.border
    local inner = W - 2 * b
    local pad = ST.margin + S(4)
    -- the definition: only as tall as fits in half the screen
    local content_w = inner - 2 * pad
    local half = math.floor(Screen:getHeight() / 2)
    local others = 2 * b + ST.head_h + 2 * S(5) + 2 * S(6) + ST.bar_h + ST.shadow
    local line_h = dql.definition_line_height or S(24)
    local def_h = math.floor((half - others) / line_h) * line_h
    def_h = math.max(def_h, 3 * line_h)

    if dql.text_widget and dql.text_widget.free then pcall(dql.text_widget.free, dql.text_widget) end
    dql.stw_widget, dql.shw_widget = nil, nil
    dql.content_width = content_w
    dql.definition_height = def_h
    dql:_instantiateScrollWidget()

    dql.definition_widget = FrameContainer:new{
        bordersize = 0, margin = 0,
        padding = 0, padding_left = pad, padding_right = pad,
        padding_top = S(6), padding_bottom = S(6),
        dql.text_widget,
    }

    local window = FrameContainer:new{
        bordersize = b, color = BLACK, radius = ST.radius, margin = 0, padding = 0, background = WHITE,
        VerticalGroup:new{
            align = "left",
            header(dql, inner),
            rule(inner),
            dql.definition_widget,
            rule(inner),
            bottomBar(dql, inner),
        },
    }
    dql._bos_window = window
    dql.dict_frame = Shadowed:new{ window }
    dql.movable[1] = dql.dict_frame
    -- KOReader's own title bar is off screen: no taps land on it
    dql.dict_title.dimen = Geom:new{ x = -10, y = -10, w = 0, h = 0 }

    -- place it away from the word: in the other half of the screen
    local total_h = dql.dict_frame:getSize().h
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local top_m, bottom_m = ST.edge, ST.edge
    if dql.ui and dql.ui.view and dql.ui.view.footer_visible and dql.ui.view.footer then
        pcall(function() bottom_m = bottom_m + dql.ui.view.footer:getHeight() end)
    end
    local align, region = "center", Geom:new{ x = 0, y = top_m, w = sw, h = sh - top_m - bottom_m }
    local wt, wb
    for _i, bx in ipairs(dql.word_boxes or {}) do
        wt = math.min(wt or bx.y, bx.y)
        wb = math.max(wb or (bx.y + bx.h), bx.y + bx.h)
    end
    if wt then
        if (wt + wb) / 2 < sh / 2 then
            align = "bottom"
            region = Geom:new{ x = 0, y = math.max(wb + S(6), sh - bottom_m - total_h), w = sw, h = 0 }
            region.h = sh - bottom_m - region.y
        else
            align = "top"
            region = Geom:new{ x = 0, y = top_m, w = sw, h = math.max(total_h, wt - S(6) - top_m) }
        end
    end
    dql.region = region
    dql.align = align
    dql[1] = WidgetContainer:new{ align = align, dimen = region, dql.movable }
end

return M
