--[[--
The reading toolbar overlay (layout "book card on top", from the Aleph ideas):

  top     [⌂]  ═════════════ pinstripes ═════════════  [⌕]
          ┌──────┐  The War of the Worlds                  [🔖]
          │cover │  H. G. Wells
          │      │  XII · WEYBRIDGE AND SHEPPERTON
          │      │  [■■■■■■░░░░░░░░░]  34%
          └──────┘  FINISH THU · 2H 10M LEFT
                    6 PAGES LEFT IN CHAPTER
          ─────────────────────────────────────────────
          ALSO READING  ▮ MIDDLEMARCH 61%   ▮ WALDEN 12%
  ═══════ (hard shadow)
                       (the page shows through)
  ═══════
  bottom  P. 65  [■■■■|■■■□|□□□□|□□□]  34%      (chapter ticks, drag to skim)
          [CONTENTS] [NOTEBOOK] [PAGES]
          ─────────────────────────────────────────────
          [▣] GLIMPSE   │ [⊥] PIN      │ [▮] STATS
              3 OF 12   │     2 PINNED │     5-DAY STREAK

Each key of the bottom row has a figure of its own under its name (see
bos_rowdata); STATS shows a different one each time the toolbar opens.

A tap on the page (outside the panels) closes it.
--]]

local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local datetime = require("datetime")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext
local Stats = require("bos_stats")
local St = require("bos_toolbar_style")
local Look = require("bos_look")
local Glyphs = require("bos_glyphs")
local Cover = require("bos_cover")
local Reading = require("bos_reading")
local Screen = Device.screen

local BLACK, WHITE = St.BLACK, St.WHITE
local S = St.S

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./")
local function iconFile(name)
    if name:sub(1, 1) == "/" then return name end
    if not name:match("%.svg$") and not name:match("%.png$") then return name end -- a KOReader icon
    return PLUGIN_DIR .. "icons/" .. name
end

local function paintIcon(bb, name, x, y, size, white, dim)
    St.paintIcon(bb, iconFile(name), x, y, size, white, dim)
end

local drawText = St.drawText
local textWidth = St.textWidth

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local ReadingToolbar = InputContainer:extend{
    name = "bookshelfos_toolbar",
    ui = nil,
    plugin = nil,
}

function ReadingToolbar:init()
    self.screen_w = Screen:getWidth()
    self.screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.screen_w, h = self.screen_h }
    self.ges_events = {}
    for _i, g in ipairs{ "tap", "touch", "pan", "hold", "hold_pan", "pan_release", "hold_release", "swipe", "double_tap" } do
        self.ges_events["Hud_" .. g] = { GestureRange:new{ ges = g, range = self.dimen }, event = "HudGesture" }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.page_count = self.ui.document:getPageCount()
    self.file = self.ui.document.file

    local W = self.screen_w
    self.pad = St.sidePad()
    self.content_w = W - 2 * self.pad
    self.shadow = Look.SHADOW
    self.key_shadow = Look.SHADOW_SMALL

    -- top panel: keys, the book card, Also reading
    self.f_title = Look.serif(20, true)
    self.title_line_h = S(28)
    self.key_w, self.key_h = S(46), S(40)
    self.keys_y = S(10)
    self.cover_w = math.min(math.floor(W * 0.17), S(112))
    self.cover_h = math.floor(self.cover_w * 1.5)
    self.card_y = self.keys_y + self.key_h + S(14)
    self.also = Reading.alsoReading(self.ui, 3)
    self.also_h = #self.also > 0 and S(52) or 0
    local y = self.card_y + self.cover_h + self.key_shadow + S(12)
    if self.also_h > 0 then
        self.also_y = y + Look.LINE
        y = self.also_y + self.also_h
    end
    self.panel_top_h = y + S(6)
    self.top_h = self.panel_top_h + self.shadow

    -- bottom panel: the track, CONTENTS · NOTEBOOK · PAGES, the button row
    self.track_h = S(38)
    self.tab_h = S(62)
    self.row_h = S(64)
    self.bottom_h = Look.LINE + S(12) + self.track_h + S(12) + self.tab_h + self.key_shadow + S(16) + self.row_h
    local by = self.screen_h - self.bottom_h
    -- the shadow sits above the panel, on the page
    self.top_dimen = Geom:new{ x = 0, y = 0, w = W, h = self.top_h }
    self.bottom_dimen = Geom:new{ x = 0, y = by - self.shadow, w = W, h = self.bottom_h + self.shadow }
    -- the reading-stats panel hangs under the top panel
    self.stats_dimen = Geom:new{ x = 0, y = self.panel_top_h, w = W, h = Stats.height() + self.shadow }
    self.rects = {}
    -- STATS: the next figure, this time
    pcall(function() require("bos_rowdata").advance() end)
end

function ReadingToolbar:getSize()
    return self.dimen
end

-- ------------------------------------------------------------ page maths

function ReadingToolbar:pctForPage(page)
    if self.page_count <= 1 then return 0 end
    return (page - 1) / (self.page_count - 1)
end

function ReadingToolbar:pageForPct(pct)
    local p = 1 + math.floor(pct * (self.page_count - 1) + 0.5)
    return math.max(1, math.min(self.page_count, p))
end

function ReadingToolbar:currentPage()
    return self.ui:getCurrentPage()
end

function ReadingToolbar:shownPage()
    return self.preview_page or self:currentPage()
end

-- ------------------------------------------------------------ painting

--- Something failed: say so on screen (with the reason, for a report)
--- instead of taking KOReader down with it.
function ReadingToolbar:failed(what, err)
    logger.warn("ShelfTechUI: toolbar " .. what .. " failed:", err)
    if self._reported then return end
    self._reported = true
    UIManager:nextTick(function()
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = T(_("The reading toolbar hit a problem and closed. Please send this to the developer:\n\n%1"),
            tostring(err):sub(1, 300)) })
        if not self.closed then UIManager:close(self) end
    end)
end

function ReadingToolbar:paintTo(bb, x, y)
    local ok, err = pcall(self.paintAll, self, bb)
    if not ok then
        self:failed("drawing", err)
        bb:paintRect(0, 0, self.screen_w, self.panel_top_h or S(60), WHITE)
    end
end

function ReadingToolbar:paintAll(bb)
    self.rects = {}
    self:paintTop(bb)
    if self.stats_open then
        local ok, res = pcall(Stats.paint, bb, self.ui, self:currentPage(), self.panel_top_h, self:statsView())
        if ok then
            self.stats_rects = res
        else
            logger.warn("ShelfTechUI: stats panel failed:", res)
            self.stats_rects = {}
        end
        return
    end
    self:paintBottom(bb)
    self:paintPill(bb)
end

--- A square key with a hard shadow and a glyph; black while pressed.
function ReadingToolbar:key(bb, name, x, y, w, h, glyph, opts)
    opts = opts or {}
    local down = self.pressed == name
    local sh = self.key_shadow
    local o = down and sh or 0
    Look.box(bb, x + o, y + o, w, h, { shadow = down and 0 or sh, fill = down and BLACK or WHITE })
    local gs = opts.size or math.floor(math.min(w, h) * 0.5)
    glyph(bb, x + o + math.floor((w - gs) / 2), y + o + math.floor((h - gs) / 2), gs, down and WHITE or BLACK, opts.arg)
    self.rects[name] = Geom:new{ x = x, y = y, w = w + sh, h = h + sh }
end

local function wrapLines(text, face, max_w, max_lines)
    local lines, line = {}, ""
    for word in tostring(text):gmatch("%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if textWidth(try, face) <= max_w or line == "" then
            line = try
        else
            table.insert(lines, line)
            line = word
            if #lines == max_lines then break end
        end
    end
    if #lines < max_lines and line ~= "" then table.insert(lines, line)
    elseif line ~= "" then lines[max_lines] = lines[max_lines] .. "…" end
    return lines
end

function ReadingToolbar:paintTop(bb)
    local W, pad = self.screen_w, self.pad
    bb:paintRect(0, 0, W, self.panel_top_h, Look.PAPER)

    -- [⌂] pinstripes [⌕]
    local kw, kh, ky = self.key_w, self.key_h, self.keys_y
    self:key(bb, "home", pad, ky, kw, kh, Glyphs.home)
    local sx = W - pad - kw - self.key_shadow
    self:key(bb, "search", sx, ky, kw, kh, Glyphs.search)
    local gx0, gx1 = pad + kw + self.key_shadow + S(12), sx - S(12)
    Look.stripes(bb, gx0, ky + math.floor((kh - S(18)) / 2), gx1 - gx0, S(18))

    -- the book card
    local props = self.ui.doc_props or {}
    local title = props.display_title or ""
    local cy = self.card_y
    local cw, ch = self.cover_w, self.cover_h
    Cover.paint(bb, self.file, pad, cy, cw, ch, { shadow = S(4), ui = self.ui, title = title })
    local bmw, bmh = S(44), S(54)
    local bmx = W - pad - bmw - self.key_shadow
    local marked = self.ui.bookmark and self.ui.bookmark:isPageBookmarked()
    self:key(bb, "bookmark", bmx, cy, bmw, bmh,
        function(b, gx, gy, s, ink) Glyphs.bookmark(b, gx, gy, s, ink, marked) end, { size = S(26) })
    local tx = pad + cw + S(4) + S(18)
    local tw = bmx - S(12) - tx
    local page = self:shownPage()
    local ty = cy
    for _i, line in ipairs(wrapLines(title, self.f_title, tw, 2)) do
        drawText(bb, line, self.f_title, tx, ty, self.title_line_h, BLACK, tw)
        ty = ty + self.title_line_h
    end
    local authors = (props.authors or ""):gsub("\n", ", ")
    if authors ~= "" then
        Look.label(bb, authors, tx, ty + S(2), bmx - tx - S(8), S(20), 13, { keep_case = true, bold = false })
        ty = ty + S(24)
    end
    local chapter = self.ui.toc and self.ui.toc:getTocTitleByPage(page) or ""
    if chapter ~= "" then
        Look.label(bb, chapter, tx, ty + S(2), bmx - tx - S(8), S(18), 11)
    end
    -- from the bottom of the card up: pages left · forecast · progress
    local row = S(19)
    local yb = cy + ch - row
    local left = Reading.chapterPagesLeft(self.ui, page)
    Look.label(bb, T(N_("1 page left in chapter", "%1 pages left in chapter", left), left),
        tx, yb, W - pad - tx, row, 10, { color = Look.GRAY })
    yb = yb - row
    local fc = Reading.forecast(self.ui, page)
    if fc then
        Look.label(bb, fc.short, tx, yb, W - pad - tx, row, 11)
        yb = yb - row
    end
    local pct = math.floor(self:pctForPage(page) * 100 + 0.5)
    if page >= self.page_count then pct = 100 end
    local pw = Look.textWidth("100%", 11)
    local bar_h = S(12)
    local bar_y = yb - S(6) + math.floor((row - bar_h) / 2)
    local bar_w = W - pad - tx - pw - S(10)
    Look.slimTrack(bb, tx, bar_y, bar_w, bar_h, self:pctForPage(page), nil, nil)
    Look.label(bb, pct .. "%", W - pad - pw, bar_y, pw, bar_h, 11, { align = "right" })
    self.rects.card = Geom:new{ x = 0, y = cy, w = bmx - S(6), h = ch }

    -- Also reading
    if self.also_h > 0 then
        local ay = self.also_y
        bb:paintRect(pad, ay - Look.LINE, self.content_w, Look.LINE, BLACK)
        local lw = Look.label(bb, _("Also reading"), pad, ay, self.content_w, self.also_h, 10)
        local x = pad + lw + S(14)
        local mw, mh = S(24), S(36)
        self.rects.also = {}
        for _i, b in ipairs(self.also) do
            local label = T("%1 %2%", b.title, math.floor(b.pct * 100 + 0.5))
            local room = W - pad - x - mw - S(8)
            if room < S(60) then break end
            local my = ay + math.floor((self.also_h - mh) / 2)
            Cover.paint(bb, b.file, x, my, mw, mh, { shadow = S(2), border = math.max(1, S(1.5)) })
            local w = Look.label(bb, label, x + mw + S(8), ay, math.min(room, S(170)), self.also_h, 10)
            table.insert(self.rects.also, { rect = Geom:new{ x = x - S(4), y = ay, w = mw + S(16) + w, h = self.also_h }, book = b })
            x = x + mw + S(8) + w + S(18)
        end
    end

    -- panel edge (Retro: a black rule and a hard shadow)
    Look.edge(bb, 0, self.panel_top_h, W, 1, (not self.stats_open) and self.shadow or 0)
end

local ROW_BUTTONS = {
    glimpse = { label = _("Glimpse"), glyph = "picture" },
    pin = { label = _("Pin"), glyph = "pin" },
    stats = { label = _("Stats"), glyph = "stats" },
}

local TABS = {
    { key = "contents", label = _("Contents"), glyph = "contents" },
    { key = "notebook", label = _("Notebook"), glyph = "notebook" },
    { key = "pages", label = _("Pages"), glyph = "pages" },
}

function ReadingToolbar:pageLabel(page)
    local pagemap = self.ui.pagemap
    if self.preview_page == nil and pagemap and pagemap:wantsPageLabels() then
        return pagemap:getCurrentPageLabel(true)
    end
    return tostring(page)
end

function ReadingToolbar:paintBottom(bb)
    local W, H, pad = self.screen_w, self.screen_h, self.pad
    local y0 = H - self.bottom_h
    bb:paintRect(0, y0, W, self.bottom_h, Look.PAPER)
    Look.edge(bb, 0, y0, W, -1, self.shadow)
    local page = self:shownPage()

    -- P. 65  [track with chapter ticks]  34%
    local py = y0 + Look.LINE + S(12)
    local ph = self.track_h
    local left_text = T(_("p. %1"), self:pageLabel(page))
    local lw = math.max(Look.textWidth("P. 8888", 11), Look.textWidth(require("bos_look").case(left_text), 11))
    Look.label(bb, left_text, pad, py, lw, ph, 11)
    local pct = math.floor(self:pctForPage(page) * 100 + 0.5)
    if page >= self.page_count then pct = 100 end
    local rw = Look.textWidth("100%", 11)
    Look.label(bb, pct .. "%", W - pad - rw, py, rw, ph, 11, { align = "right" })
    local bx0, bx1 = pad + lw + S(14), W - pad - rw - S(14)
    local bh = S(12)
    local by = py + math.floor((ph - bh) / 2)
    local frac = self:pctForPage(page)
    local ix, iw = bx0 + Look.LINE, bx1 - bx0 - 2 * Look.LINE
    self.slider = { x0 = ix, x1 = ix + iw, y = py, h = ph, r = S(10) }
    -- the main chapters only, never closer than ~14px (a long contents shows
    -- as an even rhythm, not a comb)
    local ticks = {}
    for _i, t in ipairs(Reading.tickXs(self.ui, ix, iw, S(14))) do table.insert(ticks, t.x) end
    local origin_page = self.plugin:getOriginPage()
    local ox = (origin_page and origin_page ~= page) and self:xForPct(self:pctForPage(origin_page)) or nil
    Look.slimTrack(bb, bx0, by, bx1 - bx0, bh, frac, ticks, self.dragging and true or false, ox)

    -- CONTENTS · NOTEBOOK · PAGES
    local ty = py + ph + S(12)
    local gap = S(12)
    local tw = math.floor((self.content_w - self.key_shadow - 2 * gap) / 3)
    self.nav_rects = {}
    for i, t in ipairs(TABS) do
        local x = pad + (i - 1) * (tw + gap)
        local down = self.pressed_nav == t.key
        local o = down and self.key_shadow or 0
        Look.box(bb, x + o, ty + o, tw, self.tab_h, { shadow = down and 0 or self.key_shadow, fill = down and BLACK or WHITE })
        local ink = down and WHITE or BLACK
        local gs = S(22)
        local gy = ty + o + S(10)
        Glyphs[t.glyph](bb, x + o + math.floor((tw - gs) / 2), gy, gs, ink)
        Look.label(bb, t.label, x + o, gy + gs + S(4), tw, self.tab_h - gs - S(18), 11, { align = "center", color = ink })
        self.nav_rects[t.key] = Geom:new{ x = x, y = ty, w = tw + self.key_shadow, h = self.tab_h + self.key_shadow }
    end

    -- GLIMPSE · PIN · STATS, each with its figure
    self:paintRow(bb, page)
end

--- What a key says under its name (nil: nothing to say).
function ReadingToolbar:rowFigure(id, page)
    local Row = require("bos_rowdata")
    if id == "glimpse" then
        local c = Row.glimpse(self.ui)
        if not c then return _("Not scanned") end
        if c.total == 0 then return _("No pictures") end
        return T(_("%1 of %2"), c.seen, c.total)
    elseif id == "pin" then
        local n = Row.pins(self.ui)
        if n == 0 then return _("None yet") end
        return T(N_("1 pinned", "%1 pinned", n), n)
    elseif id == "stats" then
        return Row.stat(self.ui, page)
    end
end

function ReadingToolbar:paintRow(bb, page)
    local W, H = self.screen_w, self.screen_h
    local ry = H - self.row_h
    bb:paintRect(0, ry, W, Look.LINE, BLACK)
    local cells = {}
    for _i, b in ipairs(self.plugin:getButtons()) do
        if ROW_BUTTONS[b.id] then table.insert(cells, b) end
    end
    if #cells == 0 then return end
    self.figures = self.figures or {}
    local cw = math.floor(W / #cells)
    local inner_y, inner_h = ry + Look.LINE, self.row_h - Look.LINE
    local gs = S(26)
    self.button_rects = {}
    for i, b in ipairs(cells) do
        local spec = ROW_BUTTONS[b.id]
        if b.id == "pin" then
            local okP, Pins = pcall(require, "bos_pins")
            if okP and Pins.isPinned(self.ui, page) then spec = { label = _("Unpin"), glyph = "pin" } end
        end
        local x = (i - 1) * cw
        local w = i == #cells and (W - x) or cw
        local on = self.open_button == b.id or self.pressed == "row_" .. b.id
        if on then bb:paintRect(x, inner_y, w, inner_h, BLACK) end
        -- a short divider between cells (not at the screen edges)
        if i > 1 and not on and self.open_button ~= cells[i - 1].id then
            bb:paintRect(x, inner_y + S(14), Look.LINE, inner_h - 2 * S(14), BLACK)
        end
        local ink = on and WHITE or BLACK
        -- the figure is worked out once per opening (and after a tap on PIN)
        local fig = self.figures[b.id]
        if fig == nil then
            local okF, res = pcall(self.rowFigure, self, b.id, page)
            fig = okF and res or false
            self.figures[b.id] = fig
        end
        -- glyph | NAME
        --       | figure
        local name_h, fig_h = S(20), S(18)
        local block_h = fig and (name_h + S(2) + fig_h) or name_h
        local by = inner_y + math.floor((inner_h - block_h) / 2)
        local tx = x + S(16) + gs + S(12)
        local tw = x + w - S(10) - tx
        local gx = x + S(16)
        Glyphs[spec.glyph](bb, gx, inner_y + math.floor((inner_h - gs) / 2), gs, ink)
        Look.label(bb, spec.label, tx, by, tw, name_h, 12, { color = ink })
        if fig then
            Look.label(bb, fig, tx, by + name_h + S(2), tw, fig_h, 10,
                { color = ink, bold = false })
        end
        table.insert(self.button_rects, { rect = Geom:new{ x = x, y = ry, w = w, h = self.row_h }, button = b })
    end
end

function ReadingToolbar:xForPct(pct)
    local s = self.slider
    return math.floor(s.x0 + (s.x1 - s.x0) * math.max(0, math.min(1, pct)) + 0.5)
end

function ReadingToolbar:pctForX(x)
    local s = self.slider
    if not s or s.x1 <= s.x0 then return 0 end
    return math.max(0, math.min(1, (x - s.x0) / (s.x1 - s.x0)))
end

--- "Return to page 336": a chip floating just above the bottom panel, once
--- you have moved away with the track.
function ReadingToolbar:pillRect()
    local origin_page = self.plugin:getOriginPage()
    if not origin_page or origin_page == self:shownPage() then return nil end
    local label = origin_page
    local pagemap = self.ui.pagemap
    if pagemap and pagemap:wantsPageLabels() and self.plugin.origin and self.plugin.origin.label then
        label = self.plugin.origin.label
    end
    local text = require("bos_look").case(T(_("Return to page %1"), label))
    local isz = S(18)
    local h = S(40)
    local w = Look.textWidth(text, 12) + isz + S(32)
    local x = math.floor((self.screen_w - w) / 2)
    local y = self.screen_h - self.bottom_h - self.shadow - h - S(16)
    return Geom:new{ x = x, y = y, w = w, h = h }, text, isz
end

function ReadingToolbar:paintPill(bb)
    local r, text, isz = self:pillRect()
    if r then
        local sh = self.key_shadow
        self.rects.pill = Geom:new{ x = r.x, y = r.y, w = r.w + sh, h = r.h + sh }
        Look.box(bb, r.x, r.y, r.w, r.h, { shadow = sh })
        paintIcon(bb, "return.svg", r.x + S(12), r.y + math.floor((r.h - isz) / 2), isz)
        Look.label(bb, text, r.x + S(12) + isz + S(8), r.y, r.w - isz - S(28), r.h, 12)
    end
end

-- ------------------------------------------------------------ showing / refresh


function ReadingToolbar:onShow()
    UIManager:setDirty(self, function() return "ui", self.top_dimen end)
    UIManager:setDirty(self, function() return "ui", self.bottom_dimen end)
    return true
end

--- Repaint the bottom (page changed, slider moved…). The pill floats over the
--- page, so when it goes away the reader repaints underneath it.
function ReadingToolbar:refresh(refresh_type)
    if self.stats_open then
        UIManager:setDirty(self, refresh_type or "ui", self.stats_dimen)
        return
    end
    local old_pill = self.rects.pill
    local new_pill = self:pillRect()
    if new_pill then new_pill = Geom:new{ x = new_pill.x, y = new_pill.y, w = new_pill.w + S(2), h = new_pill.h + S(2) } end
    local region = self.bottom_dimen
    if old_pill then region = region:combine(old_pill) end
    if new_pill then region = region:combine(new_pill) end
    UIManager:setDirty(old_pill and not new_pill and self.ui or self, refresh_type or "ui", region)
end

function ReadingToolbar:onCloseWidget()
    self.closed = true
    local top, bottom = self.top_dimen, self.bottom_dimen
    local pill = self.rects.pill
    if pill then bottom = bottom:combine(pill) end
    if self.stats_open then top = top:combine(self.stats_dimen) end
    UIManager:setDirty(nil, function() return "ui", top end)
    UIManager:setDirty(nil, function() return "ui", bottom end)
    if self.plugin then self.plugin:onToolbarClosed(self) end
end

function ReadingToolbar:onClose()
    UIManager:close(self)
    return true
end

function ReadingToolbar:closeAnd(fn)
    UIManager:close(self)
    if fn then
        UIManager:nextTick(function()
            local ok, err = pcall(fn)
            if not ok then logger.warn("ShelfTechUI: action failed:", err) end
        end)
    end
end

--- Quick Settings (also what swiping down from the top opens while reading).
function ReadingToolbar:openQuickSettings()
    self:closeThen(function() require("bos_quicksettings").show() end)
end

--- Close the toolbar, let the page underneath finish repainting, then run fn.
--- Bookshelf opens its panels with an e-ink animation that draws straight to
--- the screen; if our pending repaint of the page ran after it, it would paint
--- the page over the freshly opened panel (open, but invisible).
function ReadingToolbar:closeThen(fn)
    UIManager:close(self)
    UIManager:nextTick(function()
        pcall(function() UIManager:forceRePaint() end)
        local ok, err = pcall(fn)
        if not ok then logger.warn("ShelfTechUI: action failed:", err) end
    end)
end

--- ShelfTechUI's own Contents / Notes / Go to page (or KOReader's, if turned off in Settings).
function ReadingToolbar.nav(ui, what)
    local custom = require("bos_settings_store").get("custom_nav") ~= false
    if custom then
        local Nav = require("bos_nav")
        if what == "contents" then Nav.showContents(ui)
        elseif what == "notebook" or what == "bookmarks" or what == "notes" or what == "highlights" then
            Nav.showNotebook(ui, what ~= "notebook" and what or nil)
        elseif what == "map" or what == "pages" then Nav.showPages(ui)
        else Nav.showScrubber(ui) end
        return
    end
    if what == "contents" then ui:handleEvent(Event:new("ShowToc"))
    elseif what == "notebook" or what == "notes" or what == "highlights" or what == "bookmarks" then
        ui:handleEvent(Event:new("ShowBookmark"))
    elseif what == "map" or what == "pages" then ui:handleEvent(Event:new("ShowPageBrowser"))
    else ui:handleEvent(Event:new("ShowGotoDialog")) end
end

--- Same as swiping down from the top while reading: Quick Settings.
function ReadingToolbar:openMenuFromSwipe()
    self:openQuickSettings()
end

-- ------------------------------------------------------------ buttons

function ReadingToolbar:onButton(b, rect)
    local id = b.id
    local ui = self.ui
    if self.stats_open and id ~= "stats" then
        self:showStats(false)
    end
    if id == "glimpse" then
        self:closeAnd(function() ui:handleEvent(Event:new("GlimpseShow")) end)
    elseif id == "pin" then
        local Pins = require("bos_pins")
        local was = Pins.isPinned(ui, self:currentPage())
        Pins.toggle(ui, self:currentPage())
        if self.figures then self.figures.pin = nil end
        pcall(function()
            require("ui/widget/notification"):notify(was and _("Page unpinned") or _("Page pinned"))
        end)
        self:refresh()
    elseif id == "stats" then
        if self.plugin.settings.stats_button == "koreader" then
            self:openKOReaderStats()
        else
            self:showStats(not self.stats_open)
        end
    end
end

--- BOOK and a tap on the card: KOReader's details of this book.
function ReadingToolbar:openBookPage()
    local ui = self.ui
    self:closeThen(function()
        ui:handleEvent(Event:new("ShowBookInfo"))
    end)
end

--- 🔖: bookmark this page, or take its bookmark away.
function ReadingToolbar:toggleBookmark()
    local bm = self.ui.bookmark
    if not bm then return end
    if bm.onToggleBookmark then bm:onToggleBookmark() else self.ui:handleEvent(Event:new("ToggleBookmark")) end
    UIManager:setDirty(self, "ui", self.rects.bookmark or self.top_dimen)
end

--- Briefly shows a key pressed (black), then runs fn.
function ReadingToolbar:press(name, rect, fn)
    self.pressed = name
    UIManager:widgetRepaint(self, 0, 0)
    UIManager:setDirty(nil, "fast", rect)
    UIManager:forceRePaint()
    self.pressed = nil
    fn()
end

function ReadingToolbar:openKOReaderStats()
    self:closeAnd(function() Dispatcher:execute({ book_statistics = true }) end)
end

function ReadingToolbar:statsView()
    local v = self.plugin.settings.stats_view
    for _i, k in ipairs(Stats.VIEWS) do if k == v then return v end end
    return Stats.VIEWS[1]
end

--- Shows / hides the reading-stats panel under the toolbar. While it's shown,
--- the bottom panel is hidden (the page shows there).
function ReadingToolbar:showStats(open)
    if (self.stats_open and true or false) == (open and true or false) then return end
    local bottom = self.bottom_dimen
    if self.rects.pill then bottom = bottom:combine(self.rects.pill) end
    self.stats_open = open and true or nil
    self.open_button = open and "stats" or nil
    self.preview_page = nil
    self.dragging = false
    if open then
        UIManager:setDirty(self.ui, "ui", bottom)
        UIManager:setDirty(self, "ui", self.top_dimen:combine(self.stats_dimen))
    else
        UIManager:setDirty(self.ui, "ui", self.stats_dimen:combine(self.top_dimen))
        UIManager:setDirty(self, "ui", self.top_dimen)
        local new_bottom = self.bottom_dimen
        local pill = self:pillRect()
        if pill then new_bottom = new_bottom:combine(pill) end
        UIManager:setDirty(self, "ui", new_bottom)
    end
end

function ReadingToolbar:cycleStatsView(dir)
    local views = Stats.VIEWS
    local cur = self:statsView()
    local idx = 1
    for i, v in ipairs(views) do if v == cur then idx = i break end end
    idx = (idx - 1 + dir) % #views + 1
    self.plugin.settings.stats_view = views[idx]
    self.plugin:saveSettings()
    UIManager:setDirty(self, "ui", self.stats_dimen)
end

-- ------------------------------------------------------------ navigation

function ReadingToolbar:previewAt(x)
    local page = self:pageForPct(self:pctForX(x))
    if page ~= self.preview_page then
        self.preview_page = page
        self:refresh("fast")
    end
end

function ReadingToolbar:commitAt(x)
    self.dragging = false
    local page = self:pageForPct(self:pctForX(x))
    self.preview_page = nil
    if page ~= self:currentPage() then
        self.plugin:goToPage(page)
    end
    self:refresh()
end

--- The reader's page changed while we're shown.
function ReadingToolbar:onReaderPageUpdate()
    if self.dragging then return end
    self.page_count = self.ui.document:getPageCount()
    self:refresh()
end

-- ------------------------------------------------------------ gestures

function ReadingToolbar:inSlider(pos)
    local s = self.slider
    if not s or not pos or self.stats_open then return false end
    local grow = S(8)
    return pos.x >= s.x0 - s.r - S(6) and pos.x <= s.x1 + s.r + S(6) and pos.y >= s.y - grow and pos.y < s.y + s.h + grow
end

function ReadingToolbar:inPanels(pos)
    if self.stats_open then
        return inside(pos, self.top_dimen) or inside(pos, self.stats_dimen)
    end
    return inside(pos, self.top_dimen) or inside(pos, self.bottom_dimen) or inside(pos, self.rects.pill)
end

function ReadingToolbar:statsButtonAt(pos)
    for _i, br in ipairs(self.button_rects or {}) do
        if br.button.id == "stats" and inside(pos, br.rect) then return true end
    end
end

function ReadingToolbar:onHudGesture(args, ev)
    local ok, err = pcall(self.handleHud, self, args, ev)
    if not ok then self:failed("gesture", err) end
    return true
end

function ReadingToolbar:handleHud(_args, ev)
    local g, pos = ev.ges, ev.pos
    -- Swipe (or slow drag) down from the top edge: KOReader's menu, as when reading.
    if (g == "swipe" or g == "pan") and ev.direction == "south" and not self.dragging then
        local start = g == "pan" and ev.start_pos or pos
        if start and start.y < self.screen_h / 8 then
            self:openMenuFromSwipe(ev)
            return true
        end
    end
    -- long-press on STATS: KOReader's own book statistics
    if g == "hold" and not self.dragging and self:statsButtonAt(pos) then
        self:openKOReaderStats()
        return true
    end
    -- swipe left / right on the stats panel: the other chart
    if g == "swipe" and self.stats_open and inside(pos, self.stats_dimen) then
        if ev.direction == "west" then self:cycleStatsView(1)
        elseif ev.direction == "east" then self:cycleStatsView(-1) end
        return true
    end
    if g == "touch" then
        if self:inSlider(pos) then
            self.dragging = true
            self:previewAt(pos.x)
        end
    elseif g == "pan" or g == "hold_pan" or g == "hold" then
        -- hold on the track (or a drag that started there): skim
        if not self.dragging and ((ev.start_pos and self:inSlider(ev.start_pos)) or (g == "hold" and self:inSlider(pos))) then
            self.dragging = true
        end
        if self.dragging then self:previewAt(pos.x) end
    elseif g == "pan_release" or g == "hold_release" then
        if self.dragging then self:commitAt(pos.x) end
    elseif g == "swipe" then
        if self.dragging or self:inSlider(pos) then
            self:commitAt((ev.end_pos or pos).x)
        elseif not self:inPanels(pos) then
            -- a swipe on the page: close, and let the reader turn the page
            local ui = self.ui
            UIManager:close(self)
            ui:handleEvent(Event:new("Gesture", ev))
        end
    elseif g == "tap" or g == "double_tap" then
        self:onTap(pos)
    end
    return true -- nothing leaks to the page underneath
end

function ReadingToolbar:onTap(pos)
    if self.dragging or self:inSlider(pos) then
        self:commitAt(pos.x)
        return
    end
    local r = self.rects
    if self.stats_open and inside(pos, self.stats_dimen) then
        local sr = self.stats_rects or {}
        if inside(pos, sr.prev) then
            self:cycleStatsView(-1)
        elseif inside(pos, sr.next) or inside(pos, sr.chart) then
            self:cycleStatsView(1)
        end
        return
    end
    if inside(pos, r.pill) then
        self.preview_page = nil
        self.plugin:goToOrigin()
        self:refresh()
        return
    end
    local ui = self.ui
    if inside(pos, self.top_dimen) then
        if inside(pos, r.home) then
            local plugin = self.plugin
            self:press("home", r.home, function() self:closeThen(function() plugin:goBack() end) end)
        elseif inside(pos, r.search) then
            self:press("search", r.search, function()
                self:closeAnd(function() ui:handleEvent(Event:new("ShowFulltextSearchInput")) end)
            end)
        elseif inside(pos, r.bookmark) then
            self:toggleBookmark()
        elseif inside(pos, r.card) then
            self:openBookPage()
        else
            for _i, a in ipairs(r.also or {}) do
                if inside(pos, a.rect) then
                    local file = a.book.file
                    self:closeThen(function() Reading.switchTo(ui, file) end)
                    return
                end
            end
        end
        return
    end
    if inside(pos, self.bottom_dimen) and not self.stats_open then
        for _i, br in ipairs(self.button_rects or {}) do
            if inside(pos, br.rect) then
                self:onButton(br.button, br.rect)
                return
            end
        end
        self:navAt(pos)
        return
    end
    -- on the page: close
    UIManager:close(self)
end

--- CONTENTS / NOTEBOOK / PAGES: pressed (black) for a moment, then the
--- toolbar closes and that page opens.
function ReadingToolbar:navAt(pos)
    for key, r in pairs(self.nav_rects or {}) do
        if inside(pos, r) then
            local ui = self.ui
            self.pressed_nav = key
            UIManager:widgetRepaint(self, 0, 0)
            UIManager:setDirty(nil, "fast", r)
            UIManager:forceRePaint()
            self.pressed_nav = nil
            self:closeAnd(function() ReadingToolbar.nav(ui, key) end)
            return true
        end
    end
end

ReadingToolbar.paintIcon = paintIcon
ReadingToolbar.iconFile = iconFile

return ReadingToolbar
