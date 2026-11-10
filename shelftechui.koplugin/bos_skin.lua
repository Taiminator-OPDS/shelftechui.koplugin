--[[
Bookshelf look for KOReader's own screens. Each one can be turned off in
Settings → ShelfTechUI → KOReader screens; anything that fails falls back to
KOReader's stock look.

  Lists — Contents, Bookmarks, the page list, search results
      a Bookshelf header: bold title, then a chip strip to move between
      CONTENTS · BOOKMARKS · PAGES · RESULTS (and, on bookmarks, ALL ·
      HIGHLIGHTS · NOTES · BOOKMARKS filter chips); grey hairlines between
      rows; page numbers in outlined chips (the current one filled black);
      the page counter in a chip; Bookshelf's font.
  Dictionary — a Bookshelf card (2px outline, small radius, hard shadow),
      Bookshelf's font in its title, and its buttons as chips.
  Skim bar — the same card; its buttons as chips; Bookshelf's progress bar.
  Search — the search dialogs (in a book and in the file browser), with
      chip buttons and a Bookshelf title.
  Toasts — KOReader's small notifications as a black chip.

How: class-level hooks, installed once. Buttons, button tables and title bars
take the Bookshelf look only while one of these screens is being built (a
"scope"), so the rest of KOReader is untouched.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Store = require("bos_settings_store")
local UI = require("bos_ui")
local S = UI.S
local Screen = Device.screen

local Skin = { depth = 0, styles = {}, pending_menu = nil, installed = false }

local function on(key) return Store.get("skin_" .. key) ~= false end
Skin.on = on

--- Run fn with buttons, button tables and title bars in the Bookshelf look:
--- "pill" (separate rounded chips, as the skim bar) or "segment" (rows of
--- segmented strips, as the text sheet). opts.table_width: the width button
--- tables take.
function Skin.scoped(style, opts, fn, ...)
    Skin.depth = Skin.depth + 1
    table.insert(Skin.styles, { style = style, opts = opts or {} })
    local res = table.pack(pcall(fn, ...))
    table.remove(Skin.styles)
    Skin.depth = Skin.depth - 1
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

local function scope() return Skin.styles[#Skin.styles] end

local function fontName()
    local ok, f = pcall(UI.face, 16)
    return ok and f and f.realname or "cfont"
end

local function try(label, fn)
    local ok, err = pcall(fn)
    if not ok then logger.warn("ShelfTechUI: skin", label, "not applied:", err) end
end

-- ---------------------------------------------------------------------------
-- Chips: Button, ButtonTable, TitleBar (only inside a scope)
-- ---------------------------------------------------------------------------

local function installChips()
    local Button = require("ui/widget/button")
    local orig_new = Button.new
    Button.new = function(cls, o)
        local sc = scope()
        if sc and cls == Button and type(o) == "table" then
            o.text_font_face = fontName()
            o.text_font_bold = true
            if type(o.text) == "string" and not o.text_func then o.text = UI.caps(o.text) end
            if sc.style == "retro" then
                -- a square button with a hard shadow, monospaced capitals
                o.text_font_face = "stui_chrome"
                o.text_font_size = o.text_font_size or 16
                o.bordersize = UI.line()
                o.radius = require("bos_look").RADIUS
                o.background = Blitbuffer.COLOR_WHITE
                local b = orig_new(cls, o)
                pcall(function()
                    if b.frame then
                        b.frame.radius = require("bos_look").RADIUS
                        b.frame.color = Blitbuffer.COLOR_BLACK
                    end
                end)
                local orig_paint = b.paintTo
                b.paintTo = function(btn, bb, x, y)
                    local f = btn.frame or btn[1]
                    local sz = f and f:getSize() or btn:getSize()
                    if btn.enabled ~= false then
                        require("bos_look").shadow(bb, x, y, sz.w, sz.h, S(3))
                    end
                    local res = orig_paint(btn, bb, x, y)
                    require("bos_look").decorate(bb, x, y, sz.w, sz.h)
                    return res
                end
                return b
            end
            if sc.style == "segment" then
                -- a cell of a segmented strip: no border of its own
                o.bordersize = 0
                o.radius = require("bos_look").RADIUS
                o.height = o.height or S(40)
                o.padding = 0
                o.text_font_size = o.text_font_size or 15
                return orig_new(cls, o)
            end
            o.bordersize = UI.line()
            local b = orig_new(cls, o)
            -- a pill: round to half the height
            pcall(function()
                if b.frame then
                    b.frame.radius = math.floor(b.frame:getSize().h / 2)
                end
            end)
            return b
        end
        return orig_new(cls, o)
    end

    local ButtonTable = require("ui/widget/buttontable")
    local LineWidget = require("ui/widget/linewidget")
    local orig_bt_init = ButtonTable.init
    ButtonTable.init = function(self, ...)
        local sc = scope()
        if not sc then return orig_bt_init(self, ...) end
        if sc.style == "segment" then
            -- each row a segmented strip: one outline, thin black dividers,
            -- a gap between rows (the text sheet's controls)
            local FrameContainer = require("ui/widget/container/framecontainer")
            local VerticalSpan = require("ui/widget/verticalspan")
            local b = Size.border.default
            self.width = self.width - 2 * b
            self.sep_width = b
            self.zero_sep = false
            local r = orig_bt_init(self, ...)
            local rows = {}
            for _i, w in ipairs(self.container) do
                if getmetatable(w) == require("ui/widget/horizontalgroup") then
                    for _j, c in ipairs(w) do
                        if getmetatable(c) == LineWidget then c.background = Blitbuffer.COLOR_BLACK end
                    end
                    table.insert(rows, FrameContainer:new{ bordersize = b, margin = 0, padding = 0,
                        color = Blitbuffer.COLOR_BLACK, background = Blitbuffer.COLOR_WHITE, w })
                end
            end
            self.container:clear()
            for i, row in ipairs(rows) do
                if i > 1 then table.insert(self.container, VerticalSpan:new{ width = S(10) }) end
                table.insert(self.container, row)
            end
            self.width = self.width + 2 * b
            return r
        end
        self.sep_width = S(8) -- the gap between chips
        if sc.style == "retro" then self.sep_width = S(12) end
        local r = orig_bt_init(self, ...)
        if sc.style == "retro" then
            -- room for the last row's shadows
            table.insert(self.container, require("ui/widget/verticalspan"):new{ width = S(8) })
        end
        -- separators become gaps
        local function whiten(w, d)
            if d > 4 or type(w) ~= "table" then return end
            if getmetatable(w) == LineWidget then
                w.background = Blitbuffer.COLOR_WHITE
            end
            for _i, c in ipairs(w) do whiten(c, d + 1) end
        end
        whiten(self.container, 0)
        return r
    end

    local TitleBar = require("ui/widget/titlebar")
    local orig_tb_new = TitleBar.new
    TitleBar.new = function(cls, o)
        if scope() and cls == TitleBar and type(o) == "table" then
            o.title_face = o.title_face or (UI.boldFace(20))
            if scope().opts.title_line ~= false then
                o.with_bottom_line = true
                o.bottom_line_color = Blitbuffer.COLOR_LIGHT_GRAY
            end
        end
        return orig_tb_new(cls, o)
    end
end

-- ---------------------------------------------------------------------------
-- Lists: Contents, Bookmarks, the page list, search results
-- ---------------------------------------------------------------------------

local function readerUI()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    return ReaderUI and ReaderUI.instance
end

--- The navigator: CONTENTS · BOOKMARKS · PAGES · RESULTS.
local function navigatorCells(menu, kind)
    if kind == "files" then return nil end
    local ui = readerUI()
    if not ui then return nil end
    local function go(event)
        return function()
            menu:onClose()
            UIManager:nextTick(function() ui:handleEvent(Event:new(event)) end)
        end
    end
    local cells = {
        { text = _("Contents"), selected = kind == "toc", callback = go("ShowToc") },
        { text = _("Bookmarks"), selected = kind == "bookmarks", callback = go("ShowBookmark") },
    }
    local has_pages = false
    pcall(function() has_pages = ui.pagemap and ui.pagemap:wantsPageLabels() end)
    if has_pages or kind == "pages" then
        table.insert(cells, { text = _("Pages"), selected = kind == "pages", callback = go("ShowPageList") })
    end
    if kind == "results" or (ui.search and ui.search.findall_results and #ui.search.findall_results > 0) then
        table.insert(cells, { text = _("Results"), selected = kind == "results", callback = go("ShowFindAllResults") })
    end
    return cells
end

--- On Bookmarks: ALL · HIGHLIGHTS · NOTES · BOOKMARKS.
local function filterCells(menu)
    local ui = readerUI()
    local bm = ui and ui.bookmark
    if not bm then return nil end
    local mt = bm.match_table
    local function filter(t)
        return function()
            menu:onClose() -- (resets the filter)
            bm.match_table = t
            UIManager:nextTick(function() bm:onShowBookmark() end)
        end
    end
    local function only(kind) return mt and mt[kind] and not mt.search_str end
    return {
        { text = _("All"), selected = not mt and not bm.show_edited_only and not bm.show_drawer_only
                                      and not bm.show_color_only, callback = filter(nil) },
        { text = _("Highlights"), selected = only("highlight"), callback = filter({ highlight = true }) },
        { text = _("Notes"), selected = only("note"), callback = filter({ note = true }) },
        { text = _("Page marks"), selected = only("bookmark"), callback = filter({ bookmark = true }) },
    }
end

--- A header for a list: KOReader's title bar (Bookshelf font, left title)
--- with chip strips under it. Keeps the title bar's API (Menu calls it).
local function makeHeader(menu, kind)
    local TitleBar = require("ui/widget/titlebar")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local Sheet = require("bos_sheet")
    local w = menu.width or Screen:getWidth()
    if menu.subtitle == nil and (menu.show_path or menu.title_bar_fm_style) then menu.subtitle = "" end
    -- In a book the tabs already say which list this is: the title is the
    -- book's, and the list's own title ("Bookmarks (12)") goes under it.
    local book_title
    if kind ~= "files" then
        pcall(function()
            local ui = readerUI()
            book_title = ui and ui.doc_props and ui.doc_props.display_title
        end)
        if book_title == "" then book_title = nil end
    end
    local tb = TitleBar:new{
        width = w,
        fullscreen = "true",
        align = "left",
        title = book_title or menu.title,
        title_face = (UI.boldFace(22)),
        subtitle = book_title and ((menu.title and menu.title ~= "") and menu.title or " ") or menu.subtitle,
        subtitle_face = UI.italicFace(15),
        title_top_padding = S(6),
        button_padding = S(5),
        left_icon = menu.title_bar_left_icon,
        left_icon_size_ratio = 1,
        left_icon_tap_callback = function() menu:onLeftButtonTap() end,
        left_icon_hold_callback = function() menu:onLeftButtonHold() end,
        right_icon_size_ratio = 1,
        close_callback = function() menu:onClose() end,
        show_parent = menu.show_parent or menu,
    }
    if kind == "files" then pcall(function() require("bos_retro").pinstripeTitleBar(tb) end) end
    local pad = S(14)
    local group = VerticalGroup:new{ align = "left",
        require("ui/widget/linewidget"):new{ dimen = Geom:new{ w = w, h = Sheet.STYLE.top_rule },
            background = Blitbuffer.COLOR_BLACK },
        tb }
    local function strip(cells, h)
        if not cells or #cells < 2 then return end
        table.insert(group, VerticalSpan:new{ width = S(8) })
        table.insert(group, HorizontalGroup:new{ HorizontalSpan:new{ width = pad },
            Sheet.strip(cells, w - 2 * pad, { height = h }) })
    end
    strip(navigatorCells(menu, kind))
    if kind == "bookmarks" then strip(filterCells(menu), S(34)) end
    table.insert(group, VerticalSpan:new{ width = S(8) })
    -- The title bar's ☰ and ✕ have tap zones reaching well below the bar
    -- (KOReader makes them easy to hit), right over the tabs: let the tabs
    -- see a tap first, so CONTENTS / BOOKMARKS / the filters never open the
    -- ☰ menu or close the list instead.
    function group:propagateEvent(event)
        for i = #self, 1, -1 do
            local w = self[i]
            if w.handleEvent and w:handleEvent(event) then return true end
        end
        return false
    end
    local header = WidgetContainer:new{ dimen = Geom:new{ w = w, h = group:getSize().h }, group }
    header.title_bar = tb
    function header:getHeight() return group:getSize().h end
    function header:getSize() return Geom:new{ w = w, h = group:getSize().h } end
    -- (with the book as the title, the list's title and its subtitle share
    -- the line under it: "Bookmarks (12) · Selected: 3")
    local cur_title, cur_sub = menu.title, nil
    local function line()
        local parts = {}
        if cur_title and cur_title ~= "" then table.insert(parts, cur_title) end
        if cur_sub and cur_sub ~= "" then table.insert(parts, cur_sub) end
        local t = table.concat(parts, " \u{00B7} ")
        return t ~= "" and t or " "
    end
    function header:setTitle(t, ...)
        if book_title then
            cur_title = t
            return tb:setSubTitle(line(), ...)
        end
        return tb:setTitle(t, ...)
    end
    function header:setSubTitle(t, ...)
        if book_title then
            cur_sub = t
            return tb:setSubTitle(line(), ...)
        end
        return tb:setSubTitle(t, ...)
    end
    function header:setLeftIcon(...) return tb:setLeftIcon(...) end
    function header:setRightIcon(...) return tb:setRightIcon(...) end
    function header:generateVerticalLayout() return tb:generateVerticalLayout() end
    function header:generateHorizontalLayout() return tb:generateHorizontalLayout() end
    return header
end

local function chipFrame(widget, filled)
    local FrameContainer = require("ui/widget/container/framecontainer")
    local TextWidget = require("ui/widget/textwidget")
    -- a fresh copy at its natural height (lists force the number to the
    -- row's height to line up baselines, which would make a tall oval)
    if widget.text then
        widget = TextWidget:new{ text = widget.text, face = widget.face, bold = widget.bold,
            fgcolor = filled and UI.WHITE or widget.fgcolor }
    elseif filled then
        widget.fgcolor = UI.WHITE
    end
    local h = widget:getSize().h
    return FrameContainer:new{
        bordersize = math.max(1, S(1.5)),
        radius = math.floor((h + 2 * S(2)) / 2),
        padding = 0, padding_top = S(1), padding_bottom = S(1),
        background = filled and UI.BLACK or UI.WHITE,
        widget,
    }
end

local REOPEN = { toc = "ShowToc", bookmarks = "ShowBookmark", pages = "ShowPageList",
    results = "ShowFindAllResults" }

--- If the Bookshelf look ever fails while a list is up (a paint or a tap
--- raising an error), log it, turn the look off for this session and reopen
--- the list in KOReader's look, rather than leaving a half-drawn or frozen
--- screen.
function Skin.guard(menu, kind)
    local function heal(err)
        if Skin.lists_broken then return end
        Skin.lists_broken = true
        logger.warn("ShelfTechUI: list look failed, back to KOReader's look:", err)
        UIManager:nextTick(function()
            pcall(function() menu:onClose() end)
            local ui = readerUI()
            if ui and REOPEN[kind] then
                UIManager:nextTick(function() ui:handleEvent(Event:new(REOPEN[kind])) end)
            end
        end)
    end
    local orig_paint = menu.paintTo
    menu.paintTo = function(m, ...)
        local ok, err = pcall(orig_paint, m, ...)
        if not ok then heal(err) end
    end
    local orig_event = menu.handleEvent
    menu.handleEvent = function(m, ...)
        local res = table.pack(pcall(orig_event, m, ...))
        if not res[1] then heal(res[2]) return true end
        return unpack(res, 2, res.n)
    end
end

local function installLists()
    local Menu = require("ui/widget/menu")
    -- MenuItem is local to menu.lua: reach it through Menu.updateItems
    local MenuItem
    for i = 1, 60 do
        local n, v = debug.getupvalue(Menu.updateItems, i)
        if not n then break end
        if n == "MenuItem" then MenuItem = v break end
    end

    local orig_init = Menu.init
    Menu.init = function(self, ...)
        local kind = Skin.pending_menu
        Skin.pending_menu = nil
        if not kind then return orig_init(self, ...) end
        self._bos_skin = kind
        self.line_color = Blitbuffer.COLOR_LIGHT_GRAY
        local ok, header = pcall(makeHeader, self, kind)
        if ok then self.custom_title_bar = header
        else logger.warn("ShelfTechUI: list header failed:", header) end
        local r = orig_init(self, ...)
        Skin.guard(self, kind)
        -- the page counter as a chip
        pcall(function()
            local t = self.page_info_text
            t.bordersize = UI.line()
            t.radius = S(14)
            t.text_font_bold = true
            t.text_font_face = fontName()
            t.padding_h = S(14)
            -- (setText skips re-building when the text is unchanged)
            t:free()
            t:init()
            self:updatePageInfo()
        end)
        return r
    end

    if MenuItem then
        local orig_item_init = MenuItem.init
        MenuItem.init = function(self, ...)
            local menu = self.menu
            if not (menu and menu._bos_skin) then return orig_item_init(self, ...) end
            self.font = fontName()
            self.infont = fontName()
            -- room for the chip's padding, measured with the text
            local pad = "\u{2002}"
            local m = self.mandatory_func and self.mandatory_func() or self.mandatory
            local has_m = m ~= nil and tostring(m) ~= ""
            if has_m then
                self.mandatory_func = nil
                self.mandatory = pad .. tostring(m) .. pad
            end
            local r = orig_item_init(self, ...)
            if has_m then
                pcall(function()
                    local og = self._underline_container[1][1]
                    local container = og[3]
                    local mw = container[1]
                    local current = self.bold and not self.dim
                    if mw[1] and mw[3] then -- dots, span, number
                        mw[3] = chipFrame(mw[3], current)
                        mw:resetLayout()
                    else
                        container[1] = chipFrame(mw, current)
                    end
                end)
            end
            return r
        end
    else
        logger.warn("ShelfTechUI: no MenuItem in this KOReader; list rows keep their look")
    end

    -- which handler builds which list
    local function tag(path, method, kind)
        local okM, mod = pcall(require, path)
        if not (okM and mod and type(mod[method]) == "function") then return end
        local orig = mod[method]
        mod[method] = function(...)
            if on("search") and not Skin.lists_broken then Skin.pending_menu = kind end
            local res = table.pack(pcall(orig, ...))
            Skin.pending_menu = nil
            if not res[1] then error(res[2], 0) end
            return unpack(res, 2, res.n)
        end
    end
    -- (Contents and Bookmarks keep KOReader's own look)
    tag("apps/filemanager/filemanagerfilesearcher", "onShowSearchResults", "files")
end

-- ---------------------------------------------------------------------------
-- A card: 2px outline, small radius, Bookshelf's hard shadow
-- ---------------------------------------------------------------------------

local function cardify(frame)
    frame.radius = require("bos_look").RADIUS
    frame.bordersize = UI.line()
    local orig_paint = frame.paintTo
    frame.paintTo = function(f, bb, x, y)
        local sz = f:getSize()
        require("bos_look").shadow(bb, x, y, sz.w, sz.h, S(4))
        local res = orig_paint(f, bb, x, y)
        require("bos_look").decorate(bb, x, y, sz.w, sz.h)
        return res
    end
end

--- Wrap `Class.method` so it runs in a chip scope (when `key` is on), then
--- `after(self)`.
local function scopeMethod(Class, method, key, style, opts_fn, after)
    if not (Class and type(Class[method]) == "function") then return end
    local orig = Class[method]
    Class[method] = function(self, ...)
        if not on(key) then return orig(self, ...) end
        local res = table.pack(Skin.scoped(style, opts_fn and opts_fn(self, ...) or nil, orig, self, ...))
        if after then try(method, function() after(self) end) end
        return unpack(res, 1, res.n)
    end
end

local function installDictionary()
    local DQL = require("ui/widget/dictquicklookup")
    local orig = DQL.init
    DQL.init = function(self, ...)
        local r = orig(self, ...)
        if on("dictionary") then
            local ok, err = pcall(require("bos_dict").restyle, self)
            if not ok then logger.warn("ShelfTechUI: dictionary window:", err) end
        end
        return r
    end
end

local function installSkim()
    local Skim = require("ui/widget/skimtowidget")
    scopeMethod(Skim, "init", "skim", "pill", nil, function(self)
        if self.skimto_frame then cardify(self.skimto_frame) end
        local p = self.progress_bar
        if p then
            p.radius = math.floor(p.height / 2)
            p.bordersize = UI.line()
            p.bordercolor = UI.BLACK
            p.fillcolor = UI.DARK
        end
    end)
end

-- ---------------------------------------------------------------------------
-- The highlight menu (after selecting text) and a highlight's edit menu
-- ---------------------------------------------------------------------------

--- A ButtonDialog as a Bookshelf sheet: rows of segmented strips, a card with
--- a black top rule, and (for a selection) the text quoted at the top.
local function sheetDialog(dialog)
    local frame = dialog.movable and dialog.movable[1]
    if not frame then return end
    frame.radius = require("bos_look").RADIUS
    frame.bordersize = UI.line()
    frame.padding = S(10)
    frame.padding_top = S(12)
    frame.padding_bottom = S(12)
    local orig_paint = frame.paintTo
    frame.paintTo = function(f, bb, x, y)
        local sz = f:getSize()
        require("bos_look").shadow(bb, x, y, sz.w, sz.h, S(4))
        orig_paint(f, bb, x, y)
        require("bos_look").decorate(bb, x, y, sz.w, sz.h)
        bb:paintRect(x + f.radius, y, sz.w - 2 * f.radius, S(4), require("bos_look").INK)
    end
end

local function installHighlight()
    local okH, RH = pcall(require, "apps/reader/modules/readerhighlight")
    if not okH then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local orig_bd = ButtonDialog.init
    ButtonDialog.init = function(self, ...)
        local sc = scope()
        if sc and sc.opts.sheet then
            if sc.opts.quote and not self.title then
                self.title = sc.opts.quote
                self.title_align = "left"
                self.title_face = UI.italicFace(16)
            end
            local r = orig_bd(self, ...)
            pcall(sheetDialog, self)
            return r
        end
        return orig_bd(self, ...)
    end
    local function quoteOf(hl, text)
        local t = text or (hl.selected_text and hl.selected_text.text)
        if type(t) ~= "string" or t == "" then return nil end
        t = t:gsub("%s+", " ")
        if #t > 90 then t = t:sub(1, 90):gsub("[\128-\191]*$", ""):gsub("%s+%S*$", "") .. "…" end
        return "\u{201C}" .. t .. "\u{201D}"
    end
    scopeMethod(RH, "onShowHighlightMenu", "highlight", "segment",
        function(self) return { sheet = true, quote = quoteOf(self) } end)
    scopeMethod(RH, "showHighlightDialog", "highlight", "segment",
        function(self, index)
            local item = self.ui and self.ui.annotation and self.ui.annotation.annotations[index]
            return { sheet = true, quote = item and quoteOf(self, item.text) }
        end)
end

local function installSearch()
    local okS, RS = pcall(require, "apps/reader/modules/readersearch")
    -- (the search within a book is retro: bos_search; the file search: bos_retro)
    local _unused = okS and RS
end

-- ---------------------------------------------------------------------------
-- Toasts
-- ---------------------------------------------------------------------------

local function installToasts()
    local Notification = require("ui/widget/notification")
    local orig = Notification.init
    Notification.init = function(self, ...)
        local r = orig(self, ...)
        if not on("toasts") then return r end
        try("toast", function()
            -- a small retro window: a pinstriped strip with a close box and
            -- NOTICE over the message (Bookshelf's bold font), square, a
            -- 2px outline and a hard shadow
            local Retro = require("bos_retro")
            local TextWidget = require("ui/widget/textwidget")
            local FrameContainer = require("ui/widget/container/framecontainer")
            local VerticalGroup = require("ui/widget/verticalgroup")
            local face, bold = UI.boldFace(16)
            local max_w = Screen:getWidth() - 2 * self.margin - S(60)
            local text = TextWidget:new{ text = tostring(self.text or ""):gsub("%s+", " "), face = face, bold = bold,
                max_width = max_w }
            local tw = text:getSize().w
            local w = math.max(tw + 2 * S(16), S(170))
            local strip = Retro.TitleStrip:new{ width = w, height = S(22), caption = _("Notice"), size = 11 }
            local body = FrameContainer:new{ bordersize = 0, margin = 0, background = UI.WHITE,
                padding = 0, padding_left = S(16), padding_right = S(16), padding_top = S(8), padding_bottom = S(10),
                text }
            local window = FrameContainer:new{ bordersize = UI.line(), color = UI.BLACK, radius = require("bos_look").RADIUS, margin = 0,
                padding = 0, background = UI.WHITE,
                VerticalGroup:new{ align = "left", strip, body } }
            local frame = FrameContainer:new{ bordersize = 0, padding = 0, margin = self.margin,
                Retro.Shadowed:new{ shadow = S(4), window } }
            self.frame = frame
            self[1][2] = frame
            self[1]:resetLayout()
        end)
        return r
    end
end

function Skin.install()
    if Skin.installed then return end
    Skin.installed = true
    try("chips", installChips)
    try("lists", installLists)
    try("dictionary", installDictionary)
    try("skim", installSkim)
    try("search", installSearch)
    try("highlight", installHighlight)
    try("retro dialogs", function() require("bos_retro").installDialogs() end)
    try("retro menu", function() require("bos_retro").installMenu() end)
    try("retro file search", function() require("bos_retro").installSearch() end)
    try("toasts", installToasts)
end

return Skin
