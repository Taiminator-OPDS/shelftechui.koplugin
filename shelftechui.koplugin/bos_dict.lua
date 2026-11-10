--[[
The dictionary, as a small retro window: at most half the screen, square
corners, a hard black shadow, a pinstriped title bar with a close box, and a
monospaced face for its chrome (the classic desktop look, in black and white,
which suits e-ink).

    ┌─────────────────────────────────────────┐
    │[■]≡≡≡≡≡≡≡≡[ OXFORD ENGLISH ]≡≡≡≡≡≡≡[1/3]│  title: tap = dictionaries
    │ lamp                                [✎] │  the word (✎: look up another)
    │ ┌─────────────────────────────────────┐ │
    │ │ the definition, scrolling           │ │
    │ └─────────────────────────────────────┘ │
    │ [▤ DICTS ▴]  [DICT] [WIKI] [HIGHLIGHT]  │
    └─────────────────────────────────────────┘▒

  * DICTS ▴ (the "start" button) pops a start menu up: every dictionary with
    a result (the one shown, filled), then everything else the window can do
    (Search, Translate, Vocabulary builder, plugins' buttons…).
  * DICT / WIKI / HIGHLIGHT: chips. WIKI looks the word up on Wikipedia, DICT
    goes back to the dictionaries, HIGHLIGHT keeps the word highlighted.

KOReader's DictQuickLookup does all the work; this only re-lays its window
out. Its own widgets (title bar, buttons) stay alive off screen, so all of its
methods keep working.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
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
    border  = S(2),   -- window and control outlines
    shadow  = S(5),   -- the window's hard shadow
    cshadow = S(3),   -- a control's hard shadow
    title_h = S(32),
    word_h  = S(44),
    bar_h   = S(50),
    margin  = S(10),  -- inside the window
    field_pad = S(8), -- inside the definition field
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
M.box = box

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

local SKIP_IN_MENU = { prev_dict = true, next_dict = true, close = true, highlight = true, vocabulary = true }

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

local function titleBar(dql, w)
    local h = ST.title_h
    local close_sz = S(18)
    return Painted:new{
        width = w, height = h,
        draw = function(self, bb, x, y)
            bb:paintRect(x, y, w, h, WHITE)
            -- the theme's band (Retro: pinstripes)
            local top, bottom = y + S(7), y + h - S(7)
            require("bos_look").stripes(bb, x + S(4), top, w - S(8), bottom - top + 1)
            -- close box
            local cx, cy = x + S(12), y + math.floor((h - close_sz) / 2)
            bb:paintRect(cx - S(4), y + S(5), close_sz + S(8), h - S(10), WHITE)
            box(bb, cx, cy, close_sz, close_sz, { border = S(2) })
            self.close_rect = Geom:new{ x = cx - S(8), y = y, w = close_sz + S(16), h = h }
            -- the count, at the right ("2/5")
            local count = dql.displaynb
            local right = x + w - S(10)
            if count and count ~= "" then
                local cw = textWidth(count, 13) + S(14)
                bb:paintRect(right - cw, y + S(5), cw, h - S(10), WHITE)
                drawText(bb, count, right - cw, y, cw, h, { size = 13, align = "center" })
                right = right - cw - S(4)
            end
            -- the dictionary's name, centred in a white box over the stripes
            local name = require("bos_look").case((dql.displaydictname or ""))
            local left = cx + close_sz + S(12)
            local avail = right - left - S(8)
            local nw = math.min(avail, textWidth(name, 13) + S(20))
            local nx = left + math.floor((avail - nw) / 2)
            bb:paintRect(nx, y + S(4), nw, h - S(8), WHITE)
            drawText(bb, name, nx + S(10), y, nw - S(20), h, { size = 13, align = "center" })
            self.name_rect = Geom:new{ x = left, y = y, w = right - left, h = h }
            -- the rule under the bar
            bb:paintRect(x, y + h - ST.border, w, ST.border, BLACK)
        end,
        tap = function(self, pos)
            if inside(pos, self.close_rect) then
                dql:onClose()
                return true
            end
            M.openStartMenu(dql, dql._bos_start and dql._bos_start.dimen)
            return true
        end,
        hold = function(self, pos)
            if inside(pos, self.close_rect) then
                dql:onHoldClose()
                return true
            end
            -- hold the name: make this dictionary the preferred one (as KOReader)
            if not dql.is_wiki and dql.ui then
                dql.ui:handleEvent(Event:new("TogglePreferredDict", dql.dictionary))
                dql:changeDictionary(dql.dict_index)
                return true
            end
        end,
    }
end

local function wordRow(dql, w)
    local h = ST.word_h
    local btn = S(34)
    local word = dql.lookup_word_text
    -- + VOCAB: KOReader's vocabulary builder, when it offers its button here
    local vb = dql.button_table and dql.button_table:getButtonById("vocabulary")
    local vocab_label = function()
        return dql._vocabbuilder_action_state == false and "\u{2713} VOCAB" or "+ VOCAB"
    end
    local vocab_w = vb and (math.max(textWidth("\u{2713} VOCAB", 13), textWidth("+ VOCAB", 13)) + S(18)) or 0
    local vocab = vb and Painted:new{
        width = vocab_w + ST.cshadow, height = btn + ST.cshadow,
        draw = function(self, bb, x, y)
            local on = dql._vocabbuilder_action_state == false
            local down = on or self.pressed
            local ox = down and ST.cshadow or 0
            box(bb, x + ox, y + ox, vocab_w, btn, { shadow = down and 0 or ST.cshadow,
                fill = down and BLACK or WHITE })
            drawText(bb, vocab_label(), x + ox, y + ox, vocab_w, btn,
                { size = 13, align = "center", color = down and WHITE or BLACK })
        end,
        tap = function(self)
            if vb.callback then vb.callback() end
            -- (removing asks first: repaint once that's answered too)
            self:repaint()
            UIManager:scheduleIn(0.5, function() self:repaint() end)
            return true
        end,
    } or nil
    word.max_width = w - 2 * ST.margin - btn - S(10) - (vocab and (vocab.width + S(8)) or 0)
    pcall(function() word:setText(dql.displayword) end)
    local edit = Painted:new{
        width = btn + ST.cshadow, height = btn + ST.cshadow,
        draw = function(self, bb, x, y)
            box(bb, x, y, btn, btn, { shadow = self.pressed and 0 or ST.cshadow,
                fill = self.pressed and BLACK or WHITE })
            local g = TextWidget:new{ text = UI.GLYPH.pencil, face = UI.symbolFace(UI.ptForPx(S(16))),
                fgcolor = self.pressed and WHITE or BLACK }
            local sz = g:getSize()
            g:paintTo(bb, x + math.floor((btn - sz.w) / 2), y + math.floor((btn - sz.h) / 2))
            g:free()
        end,
        tap = function()
            dql:onLookupInputWord(dql.word)
            return true
        end,
        hold = function()
            dql:onLookupInputWord(dql.lookupword)
            return true
        end,
    }
    dql._bos_vocab = vocab
    local dim = Geom:new{ w = w, h = h }
    local right = HorizontalGroup:new{ overlap_align = "right" }
    if vocab then
        table.insert(right, CenterContainer:new{ dimen = Geom:new{ w = vocab.width, h = h }, vocab })
        table.insert(right, HorizontalSpan:new{ width = S(8) })
    end
    table.insert(right, CenterContainer:new{ dimen = Geom:new{ w = btn + ST.cshadow, h = h }, edit })
    table.insert(right, HorizontalSpan:new{ width = ST.margin })
    return OverlapGroup:new{
        dimen = dim,
        LeftContainer:new{ dimen = dim:copy(), HorizontalGroup:new{ HorizontalSpan:new{ width = ST.margin }, word } },
        right,
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

--- The chips: DICT · WIKI · HIGHLIGHT.
local function chipCells(dql)
    local hl = dql.button_table and dql.button_table:getButtonById("highlight")
    return {
        {
            text = _("Dict"),
            selected = function() return not dql.is_wiki end,
            callback = function()
                if dql.is_wiki then switchDomain(dql) end
            end,
        },
        {
            text = _("Wiki"),
            selected = function() return dql.is_wiki end,
            callback = function()
                if not dql.is_wiki then switchDomain(dql) end
            end,
        },
        {
            text = _("Highlight"),
            label = function() return dql._bos_hl_item and _("\u{2713} Highlighted") or _("Highlight") end,
            selected = function() return dql._bos_hl_item ~= nil end,
            enabled = dql.highlight ~= nil and not dql.is_wiki and not dql:isDocless(),
            -- right away, not when the window closes (KOReader's way): the
            -- highlight appears on the page, and tapping again takes it off
            callback = function() M.toggleHighlight(dql) end,
        },
    }
end

local function bottomBar(dql, w)
    local h = ST.bar_h
    local ch = S(34)
    local start_label = dql.is_wiki and _("Wiki") or _("Dicts")
    local start_w = textWidth(require("bos_look").case(start_label) .. " \u{25B4}", 14) + S(46)
    local start = Painted:new{
        width = start_w + ST.cshadow, height = ch + ST.cshadow,
        draw = function(self, bb, x, y)
            local down = self.open
            local ox = down and ST.cshadow or 0
            box(bb, x + ox, y + ox, start_w, ch, { shadow = down and 0 or ST.cshadow,
                fill = down and BLACK or WHITE })
            local ink = down and WHITE or BLACK
            local g = TextWidget:new{ text = UI.GLYPH.dictionary, face = UI.symbolFace(UI.ptForPx(S(15))),
                fgcolor = ink }
            local sz = g:getSize()
            g:paintTo(bb, x + ox + S(10), y + ox + math.floor((ch - sz.h) / 2))
            g:free()
            drawText(bb, require("bos_look").case(start_label) .. " \u{25B4}", x + ox + S(10) + sz.w + S(8), y + ox,
                start_w - sz.w - S(26), ch, { size = 14, color = ink })
        end,
        tap = function(self)
            M.openStartMenu(dql, self.dimen)
            return true
        end,
    }
    dql._bos_start = start
    -- the chips share the rest of the bar
    local cells = chipCells(dql)
    local gap = S(8)
    local chips_w = w - 2 * ST.margin - start.width - S(14)
    local cw = math.floor((chips_w - gap * (#cells - 1) - ST.cshadow) / #cells)
    local size = 14
    for _i, c in ipairs(cells) do
        local longest = c.label and _("\u{2713} Highlighted") or c.text
        while size > 10 and textWidth(require("bos_look").case(longest), size) > cw - S(10) do size = size - 1 end
    end
    local chips = Painted:new{
        width = chips_w, height = ch + ST.cshadow,
        draw = function(self, bb, x, y)
            self.rects = {}
            for i, c in ipairs(cells) do
                local cx = x + (i - 1) * (cw + gap)
                local sel = c.selected()
                local en = c.enabled ~= false
                local pressed = self.pressed == i
                local ox = (sel or pressed) and ST.cshadow or 0
                box(bb, cx + ox, y + ox, cw, ch, {
                    shadow = (sel or pressed) and 0 or ST.cshadow,
                    fill = (sel or pressed) and BLACK or WHITE,
                    color = en and BLACK or GRAY,
                })
                local label = require("bos_look").case((c.label and c.label() or c.text))
                drawText(bb, label, cx + ox + S(4), y + ox, cw - S(8), ch,
                    { size = size, align = "center", color = (sel or pressed) and WHITE or (en and BLACK or GRAY) })
                self.rects[i] = Geom:new{ x = cx, y = y, w = cw + ST.cshadow, h = ch + ST.cshadow }
            end
        end,
        tap = function(self, pos)
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
    local dim = Geom:new{ w = w, h = h }
    return OverlapGroup:new{
        dimen = dim,
        LeftContainer:new{ dimen = dim:copy(), HorizontalGroup:new{
            HorizontalSpan:new{ width = ST.margin },
            start,
            HorizontalSpan:new{ width = S(14) },
            chips,
        } },
    }
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
    local field_w = inner - 2 * ST.margin
    -- the definition: narrower (it sits in a field), and only as tall as fits
    -- in half the screen
    local content_w = field_w - 2 * Size1() - 2 * ST.field_pad
    local half = math.floor(Screen:getHeight() / 2)
    local others = 2 * b + ST.title_h + ST.word_h + S(4) + 2 * Size1() + 2 * S(6) + ST.bar_h + ST.shadow
    local line_h = dql.definition_line_height or S(24)
    local def_h = math.floor((half - others - 2 * S(4)) / line_h) * line_h
    def_h = math.max(def_h, 3 * line_h)

    if dql.text_widget and dql.text_widget.free then pcall(dql.text_widget.free, dql.text_widget) end
    dql.stw_widget, dql.shw_widget = nil, nil
    dql.content_width = content_w
    dql.definition_height = def_h
    dql:_instantiateScrollWidget()

    dql.definition_widget = FrameContainer:new{
        bordersize = 0, margin = 0,
        padding = 0, padding_left = ST.field_pad, padding_right = ST.field_pad,
        padding_top = S(4), padding_bottom = S(4),
        dql.text_widget,
    }
    local field = FrameContainer:new{
        bordersize = Size1(), color = BLACK, margin = 0, padding = 0, background = WHITE,
        dql.definition_widget,
    }

    local window = FrameContainer:new{
        bordersize = b, color = BLACK, radius = require("bos_look").RADIUS, margin = 0, padding = 0, background = WHITE,
        VerticalGroup:new{
            align = "center",
            titleBar(dql, inner),
            wordRow(dql, inner),
            CenterContainer:new{ dimen = Geom:new{ w = inner, h = field:getSize().h + S(4) }, field },
            VerticalSpan:new{ width = S(6) },
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
