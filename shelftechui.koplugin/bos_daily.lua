--[[
Daily things for home (Aleph ideas B7, B8, B9):

  showQuote(q)     the highlight of the day (Bookshelf's quote module), whole,
                   in a sheet: the passage, your note, the book, and OPEN IN
                   BOOK · NEW QUOTE
  wordOfDay()      a word you looked up (KOReader's Vocabulary builder), a new
                   one each day: { word, context, book }
  showWord(w)      the word in a sheet, with its sentence and LOOK UP
  xrayActions()    X-Ray's actions (xray.koplugin), when it's installed: for
                   the Quick Settings tiles
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local Page = require("bos_page")
local Screen = Device.screen
local BLACK, WHITE = Look.BLACK, Look.WHITE
local S = Look.S

local M = {}

-- ---------------------------------------------------------------- a sheet

--- A retro sheet over the lower part of the screen. spec: caption, title,
--- body (italic serif), note, sub, buttons = { { text, callback, dark } }
local function sheet(spec)
    local Sheet = InputContainer:extend{ name = "stui_daily_sheet" }
    local W, H = Screen:getWidth(), Screen:getHeight()
    local w = W - 2 * S(14) - Look.SHADOW
    function Sheet:init()
        self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
        self.ges_events = { SheetTap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
        -- measure
        local iw = w - 2 * S(16)
        local h = S(30) + S(14)
        if spec.title then h = h + Page.wrap(nil, spec.title, Page.serif(17, true), 0, 0, iw, 2, S(26)) + S(8) end
        if spec.body then h = h + Page.wrap(nil, spec.body, Page.serif(15, false, true), 0, 0, iw, 14, S(24)) + S(10) end
        if spec.note then h = h + Page.wrap(nil, spec.note, Page.serif(14), 0, 0, iw - S(70), 5, S(22)) + S(26) end
        if spec.sub then h = h + S(24) end
        h = h + S(16) + S(40) + S(16)
        self.h = math.min(h, H - S(60))
        self.rect = Geom:new{ x = S(14), y = H - self.h - S(14) - Look.SHADOW, w = w, h = self.h }
    end
    function Sheet:paintTo(bb)
        local r = self.rect
        self.hits = {}
        Look.box(bb, r.x, r.y, r.w, r.h, { shadow = Look.SHADOW })
        local strip = S(30)
        Look.stripes(bb, r.x + Look.LINE, r.y + Look.LINE + S(3), r.w - 2 * Look.LINE, strip - S(6))
        bb:paintRect(r.x, r.y + strip, r.w, Look.LINE, BLACK)
        local cap = require("bos_look").case(tostring(spec.caption or ""))
        local cw = Look.textWidth(cap, 10) + S(16)
        Look.box(bb, r.x + S(10), r.y + S(4), cw, strip - S(8))
        Look.label(bb, cap, r.x + S(10), r.y + S(4), cw, strip - S(8), 10, { align = "center" })
        Look.box(bb, r.x + r.w - S(40), r.y + S(4), S(30), strip - S(8))
        Look.label(bb, "\u{00D7}", r.x + r.w - S(40), r.y + S(4), S(30), strip - S(8), 13, { align = "center" })
        self.close_rect = Geom:new{ x = r.x + r.w - S(54), y = r.y, w = S(54), h = strip + S(8) }
        local x, y = r.x + S(16), r.y + strip + S(14)
        local iw = r.w - 2 * S(16)
        local foot = r.y + r.h - S(16) - S(40)
        if spec.title then y = y + Page.wrap(bb, spec.title, Page.serif(17, true), x, y, iw, 2, S(26)) + S(8) end
        if spec.body then
            local lines = math.max(2, math.floor((foot - y - (spec.note and S(70) or 0) - (spec.sub and S(30) or 0)) / S(24)))
            local h = Page.wrap(bb, spec.body, Page.serif(15, false, true), x + S(10), y, iw - S(10), lines, S(24))
            bb:paintRect(x, y + S(2), Look.LINE, h - S(4), BLACK)
            y = y + h + S(10)
        end
        if spec.note then
            local nh = Page.wrap(nil, spec.note, Page.serif(14), 0, 0, iw - S(70), 3, S(22)) + S(12)
            Look.box(bb, x, y, iw, nh)
            Look.label(bb, _("Note"), x + S(8), y + S(6), S(56), S(18), 9)
            Page.wrap(bb, spec.note, Page.serif(14), x + S(64), y + S(6), iw - S(70), 3, S(22))
            y = y + nh + S(10)
        end
        if spec.sub then Look.label(bb, spec.sub, x, y, iw, S(20), 10, { color = Look.GRAY }) end
        local bx = x
        for _i, b in ipairs(spec.buttons or {}) do
            local bw = Look.textWidth(require("bos_look").case(b.text), 11) + S(24)
            local rr = Look.button(bb, bx, foot, bw, S(40), b.text, { on = b.dark, size = 11 })
            table.insert(self.hits, { rect = rr, fn = b.callback })
            bx = bx + bw + S(14)
        end
    end
    function Sheet:onSheetTap(_, ges)
        if Page.inside(ges.pos, self.close_rect) or not Page.inside(ges.pos, self.rect) then
            UIManager:close(self)
            return true
        end
        for _i, h in ipairs(self.hits or {}) do
            if Page.inside(ges.pos, h.rect) then
                UIManager:close(self)
                UIManager:nextTick(function()
                    local ok, err = pcall(h.fn)
                    if not ok then logger.warn("ShelfTechUI: sheet action failed:", err) end
                end)
                return true
            end
        end
        return true
    end
    function Sheet:onClose() UIManager:close(self) return true end
    function Sheet:region() return Geom:new{ x = 0, y = self.rect.y - S(4), w = W, h = H - self.rect.y + S(4) } end
    function Sheet:onShow() UIManager:setDirty(self, "ui", self:region()) return true end
    function Sheet:onCloseWidget() UIManager:setDirty(nil, "ui", self:region()) end
    UIManager:show(Sheet:new{})
end
M.sheet = sheet

-- ---------------------------------------------------------------- B7: the highlight of the day

function M.showQuote(q, ctx)
    local parts = {}
    if q.title and q.title ~= "" then table.insert(parts, q.title) end
    if q.author and q.author ~= "" then table.insert(parts, q.author) end
    local buttons = {}
    if q.filepath then
        table.insert(buttons, { text = _("Open in book"), dark = true, callback = function()
            local function goto(ui)
                pcall(function()
                    ui.link:addCurrentLocationToStack()
                    ui.bookmark:gotoBookmark(q.page, q.pos0)
                end)
            end
            local bw = ctx and ctx.bw
            if bw and bw._openBook then bw:_openBook({ filepath = q.filepath }, goto)
            else require("apps/reader/readerui"):showReader(q.filepath, nil, nil, nil, goto) end
        end })
    end
    table.insert(buttons, { text = _("New quote"), callback = function()
        pcall(function() require("lib/bookshelf_quotes").reroll() end)
        pcall(function() require("bos_home").refresh() end)
    end })
    sheet{ caption = _("Highlight of the day"), title = table.concat(parts, " · "), body = q.text, note = q.note,
        buttons = buttons }
end

-- ---------------------------------------------------------------- B8: a word of the day


function M.showWord(w)
    if not w then return end
    sheet{ caption = _("Word of the day"), title = w.word, body = w.context, sub = w.book,
        buttons = {
            { text = _("Look up"), dark = true, callback = function()
                local ui = require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
                if ui and ui.dictionary then ui.dictionary:onLookupWord(w.word) end
            end },
            { text = _("Another word"), callback = function() M.showWord(M.wordOfDay(true)) end },
        } }
end

-- ---------------------------------------------------------------- B9: X-Ray

--- X-Ray's Dispatcher actions ({ id, title }), when xray.koplugin is installed.
function M.xrayActions()
    local out = {}
    pcall(function()
        local Dispatcher = require("dispatcher")
        local list
        for i = 1, 60 do
            local n, v = debug.getupvalue(Dispatcher.registerAction, i)
            if not n then break end
            if n == "settingsList" and type(v) == "table" then list = v break end
        end
        for id, spec in pairs(list or {}) do
            if type(id) == "string" and id:lower():find("xray", 1, true) and type(spec) == "table" then
                table.insert(out, { id = id, title = spec.title or id })
            end
        end
        table.sort(out, function(a, b) return tostring(a.title) < tostring(b.title) end)
    end)
    return out
end

function M.runAction(id)
    pcall(function() require("dispatcher"):execute({ [id] = true }) end)
end

return M
