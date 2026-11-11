--[[
ShelfTechUI's retro look for Bookshelf's home screen, applied at run time so
Bookshelf's own code stays as it ships (easier to bring in its updates):

  shelves     a line shelf instead of the wooden plank: a pinstriped
              surface, a 2px black front edge and a solid black face
              (no wood texture to scale and blit)
  ornaments   none (no plants or ornaments between the books)
  depth       a hard black shadow to the right of each book instead of the
              soft image-mask shadows (one rect per book, not an alpha blit)
  bars        Bookshelf's progress bars (the hero's, the cards') as the
              retro track: a square outline, pinstriped up to the position,
              chapter ticks above it

Each patch is guarded: if Bookshelf changes, that part keeps Bookshelf's own
look instead of breaking the shelf.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local logger = require("logger")

local Look = require("bos_look")
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = {}

local function S(v) return Screen:scaleBySize(v) end

local function patch(what, fn)
    local ok, err = pcall(fn)
    if not ok then logger.warn("ShelfTechUI retro:", what, err) end
end

--- Always: the look of Bookshelf's home is the theme's (Settings → Themes).
function M.on() return true end

--- How far a footer keycap stands out round its glyph.
function M.KEY_PAD() return S(5) end

--- A shelf under the books, in the theme's way (Retro: a pinstriped surface
--- on a black front).
function M.paintShelf(bb, x, top, w, surf, fh)
    local th = Look.theme
    local front_y = top + surf
    local line = math.max(1, S(1))
    bb:paintRect(x, top, w, surf, WHITE)
    local id = th.id
    if id == "modern" then
        bb:paintRoundedRect(x, front_y, w, math.min(fh, S(6)), Blitbuffer.COLOR_GRAY_D, S(3))
    elseif id == "fantasy" then
        bb:paintRect(x, front_y - S(3), w, line, BLACK)
        bb:paintRect(x, front_y + S(1), w, line, BLACK)
    elseif id == "scifi" then
        for xx = x, x + w - 1, S(6) do bb:paintRect(xx, front_y, S(2), S(2), BLACK) end
    elseif id == "rustic" then
        -- a wooden plank: grain in greys between two dark edges
        local gy = front_y - S(2)
        bb:paintRect(x, gy, w, fh + S(2), Blitbuffer.COLOR_GRAY_B)
        for xx = x, x + w - 1, S(23) do
            bb:paintRect(xx, gy, 1, fh + S(2), Blitbuffer.COLOR_GRAY_9)
            bb:paintRect(xx + S(9), gy + S(2), S(10), 1, Blitbuffer.COLOR_GRAY_9)
        end
        bb:paintRect(x, gy, w, Look.LINE, th.ink)
        bb:paintRect(x, gy + fh + S(2), w, Look.LINE, th.ink)
    elseif id == "book" then
        for k = 0, math.min(fh, S(7)) - 1 do
            bb:paintRect(x, front_y + k, w, 1, k % 2 == 0 and th.shade or WHITE)
        end
        bb:paintRect(x, front_y, w, 1, th.ink)
    else
        for yy = top + S(2), front_y - S(3), S(3) do
            bb:paintRect(x, yy, w, line, BLACK)
        end
        -- the front edge and the face: black
        bb:paintRect(x, front_y - Look.LINE, w, Look.LINE, BLACK)
        bb:paintRect(x, front_y, w, fh, BLACK)
    end
end

--- With a theme other than Retro, Bookshelf's own text (home, chips, hero,
--- its dialogs) is set in the theme's face.
function M.themeFonts()
    if Look.theme.id == "retro" or not Look.theme.text then return end
    local ok, BF = pcall(require, "lib/bookshelf_fonts")
    if not ok or type(BF) ~= "table" or BF._stui_themed then return end
    BF._stui_themed = true
    local orig = BF.getFace
    local SYMBOLS = { symbols = true, scfont = true, infont = true, smallinfont = true, hpkfont = true }
    BF.getFace = function(self, face_name, size, opts)
        opts = opts or {}
        if not SYMBOLS[face_name] then
            local okF, f = pcall(Look.text, size or 20, opts.bold, opts.italic)
            if okF and f then return f, false end
        end
        return orig(self, face_name, size, opts)
    end
end

function M.install()
    if M._installed then return end
    M._installed = true
    M.installChrome()

    -- shelves: no wood; the line shelf
    patch("plank", function()
        local SpineShelf = require("lib/bookshelf_spine_shelf")
        -- ShelfPlank is local to the module: found through its functions
        local ShelfPlank = M.findLocal(SpineShelf, "ShelfPlank")
        if not ShelfPlank then error("ShelfPlank not found") end
        local orig_paint = ShelfPlank.paintTo
        ShelfPlank.paintTo = function(self, bb, x, y)
            if not M.on() then return orig_paint(self, bb, x, y) end
            self.dimen.x, self.dimen.y = x, y
            local w, h = self.dimen.w, self.dimen.h
            local fh = SpineShelf.plankFace(h)
            local surf = SpineShelf.plankSurface(h)
            local front_y = y + h - fh
            local top = front_y - surf
            M.paintShelf(bb, x, top, w, surf, fh)
        end
    end)

    -- depth: a hard shadow right of each book
    patch("shadows", function()
        local SpineShelf = require("lib/bookshelf_spine_shelf")
        local orig = SpineShelf.paintShadowAssets
        SpineShelf.paintShadowAssets = function(bb, x, y, cols, opts)
            if not M.on() then return orig(bb, x, y, cols, opts) end
            local sh = Look.SHADOW
            local stand_h = opts and opts.stand_h or 0
            for i = 1, #cols do
                local c = cols[i]
                local book_top = stand_h - math.min(c.h, stand_h)
                local floor = stand_h - (c.foot or 0)
                local nxt = cols[i + 1]
                -- not into the next book when they touch
                local room = nxt and (nxt.x - (c.x + c.w)) or sh
                local sw = math.max(0, math.min(sh, room))
                if sw > 0 and floor - book_top > sh and Look.theme.shadow ~= "none" then
                    bb:paintRect(x + c.x + c.w, y + book_top + sh, sw, floor - book_top - sh,
                        Look.theme.shadow == "hard" and Look.theme.shade or Look.MID)
                end
            end
            return true
        end
    end)

    -- progress bars: the retro track
    patch("bars", function()
        local Bars = require("lib/bookshelf_bar_paint")
        local orig = Bars.paintProgressBar
        Bars.paintProgressBar = function(bb, x, y, w, h, fraction, ticks, style, orientation, reverse,
                                         colors, markers)
            if not M.on() or orientation == "vertical" or style == "pacman"
                    or style == "radial" or style == "radial_hollow" or w < S(20) or h < S(4) then
                return orig(bb, x, y, w, h, fraction, ticks, style, orientation, reverse, colors, markers)
            end
            fraction = math.max(0, math.min(1, fraction or 0))
            if reverse then
                -- fill from the right
                Look.box(bb, x, y, w, h, { border = math.min(Look.LINE, math.floor(h / 3)) })
                local b = math.min(Look.LINE, math.floor(h / 3))
                local fw = math.floor((w - 2 * b) * fraction + 0.5)
                Look.fill(bb, x + w - b - fw, y + b + 1, fw, h - 2 * b - 2)
            else
                local b = math.min(Look.LINE, math.floor(h / 3))
                Look.track(bb, x, y, w, h, fraction, { border = b })
            end
            for _i, t in ipairs(ticks or {}) do
                local f = type(t) == "table" and t[1] or t
                if type(f) == "number" and f > 0 and f < 1 then
                    if reverse then f = 1 - f end
                    local tx = x + math.floor(w * f)
                    bb:paintRect(tx, y + Look.LINE, math.max(1, S(1)), math.max(1, math.floor(h / 2) - Look.LINE),
                        BLACK)
                end
            end
        end
    end)
end

--- Set the upvalue `name` of every function in `mod` that has it.
function M.setLocal(mod, name, value)
    local n_set = 0
    for _k, fn in pairs(mod) do
        if type(fn) == "function" then
            for i = 1, 300 do
                local n = debug.getupvalue(fn, i)
                if not n then break end
                if n == name then debug.setupvalue(fn, i, value) n_set = n_set + 1 end
            end
        end
    end
    return n_set
end

--- The rest of the retro look across Bookshelf (and every KOReader screen):
--- square corners, hard black shadows, the monospaced face for chrome, and
--- ShelfTechUI's icon status line on the home card.
function M.installChrome()
    if M._chrome then return end
    M._chrome = true

    -- square corners: KOReader's frames, and every Bookshelf class that
    -- paints with a `radius` (cards, panels, chips, rows), drawn square
    patch("corners", function()
        local FrameContainer = require("ui/widget/container/framecontainer")
        M.squareClass(FrameContainer)
        M.squareBookshelf()
    end)

    -- shadows: hard and black by day (night keeps Bookshelf's faint one)
    patch("shadow colours", function()
        local function setUp(fn, name, value)
            if type(fn) ~= "function" then return end
            for i = 1, 300 do
                local n = debug.getupvalue(fn, i)
                if not n then break end
                if n == name then debug.setupvalue(fn, i, value) end
            end
        end
        local SW = require("lib/bookshelf_spine_widget")
        setUp(M.findLocal(SW, "_shadowGray"), "SHADOW_GRAY_DAY", BLACK)
        local SM = require("lib/bookshelf_start_menu")
        setUp(M.findLocal(SM, "_panelShadowGray"), "PANEL_SHADOW_DAY", BLACK)
        -- square covers and cards
        M.setLocal(SW, "CARD_RADIUS", 0)
        local SR = M.findLocal(SW, "ShadowRect")
        if type(SR) == "table" then M.setLocal(SR, "CARD_RADIUS", 0) end
        local orig_sq = SW._squareCorners
        if orig_sq then
            SW._squareCorners = function(self, ...)
                if M.on() then return true end
                return orig_sq(self, ...)
            end
        end
        local CP = require("lib/bookshelf_cover_progress")
        local def = M.findLocal(CP, "DEFAULT_CARD_SHADOW")
        if type(def) == "table" then def.hex = "#000000" end
    end)

    -- module cards: white (not cream), on a hard black shadow
    patch("module cards", function()
        local CP = require("lib/bookshelf_cover_progress")
        local mbg = M.findLocal(CP, "DEFAULT_MODULE_BG")
        if type(mbg) == "table" then mbg.hex = "#FFFFFF" end
    end)

    -- Bookshelf's popups (the book menu, the shelf editor, the start menu's
    -- module rows): its grey cards become retro cards -- white, a 2px black
    -- outline, a hard black shadow, pushed onto the shadow when pressed;
    -- the grey strips under tabs white, with a black rule
    patch("popup cards", function()
        local Kit = require("lib/bookshelf_popup_kit")
        local FrameContainer = require("ui/widget/container/framecontainer")
        Kit.RADIUS = 0
        Kit.STRIP_BG = WHITE
        Kit.SHADOW = BLACK
        Kit.DIM_ON_GREY = Blitbuffer.COLOR_DARK_GRAY
        local function retroCard(frame, bb, x, y, outline)
            local sz = frame:getSize()
            sz = { w = frame.width or sz.w, h = frame.height or sz.h }
            local sh = Look.SHADOW_SMALL
            local on = frame.background == BLACK
            local o = frame._pressed and sh or 0
            if not frame._pressed then Look.shadow(bb, x, y, sz.w, sz.h, sh) end
            Look.box(bb, x + o, y + o, sz.w, sz.h, { fill = (on or frame._pressed) and BLACK or WHITE,
                border = outline and Look.LINE * 2 or Look.LINE })
            local bg, r = frame.background, frame.radius
            frame.background, frame.radius = nil, 0
            if frame._pressed and not on then
                -- white on black while pressed
                frame.background = nil
            end
            FrameContainer.paintTo(frame, bb, x + o, y + o)
            frame.background, frame.radius = bg, r
            if frame._pressed and not on then
                bb:invertRect(x + o + Look.LINE, y + o + Look.LINE, sz.w - 2 * Look.LINE, sz.h - 2 * Look.LINE)
            end
        end
        local n = 0
        for _k, fn in pairs(Kit) do
            if type(fn) == "function" then
                for i = 1, 200 do
                    local nm = debug.getupvalue(fn, i)
                    if not nm then break end
                    if nm == "paintCard" then debug.setupvalue(fn, i, retroCard) n = n + 1 end
                end
            end
        end
        if n == 0 then error("paintCard not found") end
    end)

    -- KOReader's (and Bookshelf's) button dialogs and menus: square, with
    -- the retro title strip where they have a title
    patch("button dialogs", function()
        local ButtonDialog = require("ui/widget/buttondialog")
        local Retro = require("bos_retro")
        local orig = ButtonDialog.init
        ButtonDialog.init = function(self, ...)
            local r = orig(self, ...)
            if M.on() and not self._stui_retro then
                self._stui_retro = true
                pcall(function()
                    if self.title_bar then Retro.pinstripeTitleBar(self.title_bar) end
                    local f = self.movable and self.movable[1]
                    if f and f.bordersize then
                        f.radius = 0
                        f.bordersize = Look.LINE
                        f.color = BLACK
                        if not f._bos_shadowed then
                            local sh = Retro.Shadowed:new{ f }
                            sh._bos_shadowed = true
                            self.movable[1] = sh
                        end
                    end
                end)
            end
            return r
        end
    end)

    -- text prompts (Bookshelf's "Search library", renames, notes): retro
    -- windows -- the pinstriped title, square frame, hard shadow
    patch("input dialogs", function()
        local Retro = require("bos_retro")
        Retro.installRetroInput()
        local InputDialog = require("ui/widget/inputdialog")
        local orig_new = InputDialog.new
        InputDialog.new = function(cls, o, ...)
            if type(o) == "table" and M.on() and o._bos_retro_wanted == nil then o._bos_retro_wanted = true end
            return orig_new(cls, o, ...)
        end
    end)

    -- chrome type: Bookshelf's "infofont" (tabs, chips, counters, list
    -- details) in the monospaced face
    patch("chrome font", function()
        local BFont = require("lib/bookshelf_fonts")
        local Font = require("ui/font")
        local orig = BFont.getFace
        BFont.getFace = function(self, face_name, size, opts)
            if face_name == "infofont" and M.on() then
                local px = tonumber(size) or 16
                return require("bos_look").mono(math.max(9, math.floor(px * 0.86 + 0.5))), true
            end
            return orig(self, face_name, size, opts)
        end
    end)

    -- the home card's status line: ShelfTechUI's, with icons. The card
    -- builds its own line inline: swap it once the column is built.
    -- the home footer's keys (≡ « ‹ page › » ⊞): square keycaps with a hard
    -- shadow, the page counter an inverted mono chip. Painted under each
    -- key's own glyph, so hit boxes, focus and layout stay Bookshelf's.
    patch("footer keys", function()
        local BW = require("lib/bookshelf_widget")
        local KEY_PAD = M.KEY_PAD
        -- the cap behind a glyph of w x h at x,y
        local function cap(bb, x, y, w, h, enabled, inverted)
            local p = KEY_PAD()
            Look.box(bb, x - p, y - p, w + 2 * p, h + 2 * p, {
                shadow = enabled and Look.SHADOW_SMALL or 0,
                color = enabled and BLACK or Look.LIGHT,
                fill = inverted and BLACK or WHITE })
        end
        local function hookIcon(leaf, btn)
            if type(leaf) ~= "table" or leaf._stui_key then return end
            leaf._stui_key = true
            local orig = leaf.paintTo
            leaf.paintTo = function(s, bb, x, y)
                if M.on() then
                    local sz = s:getSize()
                    cap(bb, x, y, sz.w, sz.h, not btn or btn.enabled ~= false)
                end
                return orig(s, bb, x, y)
            end
        end
        local function hookCounter(leaf, btn)
            if type(leaf) ~= "table" or leaf._stui_key then return end
            leaf._stui_key = true
            local orig = leaf.paintTo
            leaf.paintTo = function(s, bb, x, y)
                if not M.on() or type(s.text) ~= "string" then return orig(s, bb, x, y) end
                local sz = s:getSize()
                local size = 13
                local text = require("bos_look").case(s.text)
                local tw = Look.textWidth(text, size)
                local slot = btn and btn.width or sz.w
                local w = math.min(math.max(sz.w, tw + 2 * S(6)), slot - 2 * KEY_PAD() - Look.SHADOW_SMALL)
                local cx = x + math.floor((sz.w - w) / 2)
                cap(bb, cx, y, w, sz.h, true, true)
                Look.label(bb, text, cx, y, w, sz.h, size, { align = "center", color = WHITE })
            end
        end
        local function isButton(w)
            return type(w) == "table" and w.label_widget ~= nil and w.frame ~= nil
        end
        local function hookButton(b)
            if b._stui_keybtn then return end
            b._stui_keybtn = true
            local orig = b.paintTo
            -- Button:setText swaps its label widget: hook whatever is current
            b.paintTo = function(s, bb, x, y)
                local lw = s.label_widget
                if lw and not lw._stui_key then
                    if s.icon then hookIcon(lw, s) else hookCounter(lw, s) end
                end
                return orig(s, bb, x, y)
            end
        end
        local function walk(w, d)
            if type(w) ~= "table" or d > 14 then return end
            if isButton(w) then hookButton(w) return end
            for i = 1, #w do walk(w[i], d + 1) end
        end
        local orig_wrap = BW._wrapAsFooterButton
        BW._wrapAsFooterButton = function(self, content, ...)
            hookIcon(content, nil)
            return orig_wrap(self, content, ...)
        end
        local orig_row = BW._buildFooterRow
        BW._buildFooterRow = function(self, ...)
            local row = orig_row(self, ...)
            pcall(walk, row, 0)
            return row
        end
        -- the shelf rows must clear the caps, which stand KEY_PAD above the
        -- glyphs (the only caller of split is the shelf's layout)
        local GridMargins = require("lib/bookshelf_grid_margins")
        local orig_split = GridMargins.split
        GridMargins.split = function(o)
            if M.on() and type(o) == "table" and (o.foot_offset or 0) > 0 then
                o.foot_offset = math.max(0, o.foot_offset - KEY_PAD() - S(2))
            end
            return orig_split(o)
        end
    end)

    patch("hero status line", function()
        local HeroCard = require("lib/bookshelf_hero_card")
        local orig_col = HeroCard._buildRightColumn
        HeroCard._buildRightColumn = function(self, book, regions, state, dimen)
            local col = orig_col(self, book, regions, state, dimen)
            local okS, Status = pcall(require, "bos_status")
            local strip = self._status_strip_widgets
            if okS and Status.enabled() and strip and strip[1] and not strip[1]._is_job then
                local target, row = strip[1], Status.row(dimen.w, { hairline = false })
                local function swap(w, d)
                    if d > 12 or type(w) ~= "table" then return false end
                    for i = 1, #w do
                        if w[i] == target then
                            w[i] = row
                            if w.resetLayout then w:resetLayout() end
                            return true
                        end
                        if swap(w[i], d + 1) then return true end
                    end
                    return false
                end
                if swap(col, 0) then
                    strip[1] = row
                    if target.free then pcall(function() target:free() end) end
                end
            end
            return col
        end
    end)

    patch("status line", function()
        local HeroCard = require("lib/bookshelf_hero_card")
        local orig = HeroCard.buildStatusRow
        HeroCard.buildStatusRow = function(book, state, width, with_hairline, allow_job, ink)
            local okS, Status = pcall(require, "bos_status")
            if okS and Status.enabled() and not M._inner_status then
                return Status.row(width, { hairline = with_hairline ~= false })
            end
            return orig(book, state, width, with_hairline, allow_job, ink)
        end
    end)
end

--- Make a widget class paint square: its paintTo runs with radius 0.
--- A circle (radius at least half its size) stays round.
function M.squareClass(cls)
    if type(cls) ~= "table" or rawget(cls, "_stui_square") then return end
    local orig = rawget(cls, "paintTo")
    if type(orig) ~= "function" then return end
    cls._stui_square = true
    cls.paintTo = function(self, ...)
        local r = self.radius
        if r and r > 0 and M.on() then
            local d = self.dimen
            local circle = d and d.w and d.h and r * 2 >= math.min(d.w, d.h) - 2 and math.abs(d.w - d.h) <= 2
            if not circle then
                self.radius = 0
                local res = table.pack(orig(self, ...))
                self.radius = r
                return unpack(res, 1, res.n)
            end
        end
        return orig(self, ...)
    end
end

--- Every class Bookshelf has loaded so far that paints with a radius.
function M.squareBookshelf()
    local seen = {}
    local function visit(t, d)
        if type(t) ~= "table" or seen[t] or d > 3 then return end
        seen[t] = true
        if rawget(t, "paintTo") and (rawget(t, "radius") ~= nil or rawget(t, "corner_radius") ~= nil) then
            M.squareClass(t)
        end
        for _k, v in pairs(t) do
            if type(v) == "table" then visit(v, d + 1)
            elseif type(v) == "function" then
                for i = 1, 200 do
                    local n, uv = debug.getupvalue(v, i)
                    if not n then break end
                    if type(uv) == "table" and not seen[uv] then visit(uv, d + 1) end
                end
            end
        end
    end
    for name, mod in pairs(package.loaded) do
        if type(name) == "string" and name:match("^lib/bookshelf_") then visit(mod, 0) end
    end
end

--- A file-local of `mod` (a table of functions), found through the upvalues
--- of its functions.
function M.findLocal(mod, name)
    -- the module's functions, then the functions of the tables they hold
    -- (a class kept in a local), two levels deep
    local seen_fn, seen_t = {}, {}
    local queue = { mod }
    seen_t[mod] = true
    local depth = 0
    while #queue > 0 and depth < 3 do
        local nxt = {}
        for _q, t in ipairs(queue) do
            for _k, fn in pairs(t) do
                if type(fn) == "function" and not seen_fn[fn] then
                    seen_fn[fn] = true
                    for i = 1, 300 do
                        local n, v = debug.getupvalue(fn, i)
                        if not n then break end
                        if n == name then return v end
                        if type(v) == "table" and not seen_t[v] then
                            seen_t[v] = true
                            table.insert(nxt, v)
                        end
                    end
                end
            end
        end
        queue = nxt
        depth = depth + 1
    end
end

return M
