--[[
Pinned pages (Aleph idea B4): keep a page (a map, a family tree, a table) at
hand. Pin it from the highlight menu (PIN) or the toolbar's PIN key; a small
badge appears at the foot of the page once the book has pins, and opens a
drawer from the right: the pinned page, ‹ › between pins, GO TO PAGE,
FULL SCREEN and UNPIN.

Pins are kept in the book's settings (positions survive a change of font
size in reflowable books).

  list(ui)  isPinned(ui, page)  toggle(ui, page)  add(ui, page)  remove(ui, i)
  paintBadge(bb, ui) -> rect | nil      showDrawer(ui, index)
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local Glyphs = require("bos_glyphs")
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local S = Look.S

local M = {}
local KEY = "stui_pins"

local function raw(ui)
    local t = ui.doc_settings and ui.doc_settings:readSetting(KEY)
    return type(t) == "table" and t or {}
end

--- The page a pin is on now.
local function pageOf(ui, pin)
    if pin.xp and ui.rolling then
        local ok, p = pcall(ui.document.getPageFromXPointer, ui.document, pin.xp)
        if ok and p then return p end
    end
    return pin.page
end

function M.list(ui)
    local out = {}
    for _i, pin in ipairs(raw(ui)) do
        table.insert(out, { page = pageOf(ui, pin), xp = pin.xp, time = pin.time })
    end
    table.sort(out, function(a, b) return (a.page or 0) < (b.page or 0) end)
    return out
end

function M.indexOf(ui, page)
    for i, pin in ipairs(raw(ui)) do
        if pageOf(ui, pin) == page then return i end
    end
end

function M.isPinned(ui, page) return M.indexOf(ui, page or ui:getCurrentPage()) ~= nil end

local function save(ui, t)
    ui.doc_settings:saveSetting(KEY, #t > 0 and t or nil)
    UIManager:setDirty(ui, "ui")
end

function M.add(ui, page)
    page = page or ui:getCurrentPage()
    if M.isPinned(ui, page) then return end
    local t = raw(ui)
    local xp
    if ui.rolling then pcall(function() xp = ui.document:getPageXPointer(page) end) end
    table.insert(t, { page = page, xp = xp, time = os.time() })
    save(ui, t)
end

function M.remove(ui, page)
    local i = M.indexOf(ui, page)
    if not i then return end
    local t = raw(ui)
    table.remove(t, i)
    save(ui, t)
end

function M.toggle(ui, page)
    page = page or ui:getCurrentPage()
    if M.isPinned(ui, page) then M.remove(ui, page) else M.add(ui, page) end
end

-- ---------------------------------------------------------------- the badge

--- The badge above the bottom margin: [📌 2]. Returns its rect.
function M.paintBadge(bb, ui)
    local n = #raw(ui)
    if n == 0 then return nil end
    local W, H = Screen:getWidth(), Screen:getHeight()
    -- above KOReader's status bar when it shows (Bookends draws inside the page margins)
    local foot = 0
    pcall(function()
        local f = ui.view.footer
        if ui.view.footer_visible and f then
            foot = f:getHeight()
        end
    end)
    local text = tostring(n)
    local h = S(26)
    local gs = S(14)
    local w = S(8) + gs + S(5) + Look.textWidth(text, 11) + S(8)
    local x = W - S(18) - w - Look.SHADOW_SMALL
    local y = H - foot - h - S(10) - Look.SHADOW_SMALL
    Look.box(bb, x, y, w, h, { shadow = Look.SHADOW_SMALL })
    Glyphs.pin(bb, x + S(8), y + math.floor((h - gs) / 2), gs, BLACK)
    Look.label(bb, text, x + S(8) + gs + S(5), y, w, h, 11)
    return Geom:new{ x = x - S(10), y = y - S(10), w = w + S(20) + Look.SHADOW_SMALL, h = h + S(20) + Look.SHADOW_SMALL }
end

-- The badge on the page: a view module (not in page thumbnails), and a tap on it
-- opens the drawer.
local live = setmetatable({}, { __mode = "k" })
local BadgeView = {}
BadgeView.__index = BadgeView
function BadgeView:paintTo(bb)
    local ui = self.ui
    if not (ui and ui.document) or M.in_thumbnail then return end
    local ok, r = pcall(M.paintBadge, bb, ui)
    self.badge = ok and r or nil
end

function M.attach(ui)
    if not ui or not ui.view or live[ui] then return end
    local v = setmetatable({ ui = ui }, BadgeView)
    live[ui] = v
    ui.view:registerViewModule("stui_pin_badge", v)
    if not ui.registerTouchZones then return end
    ui:registerTouchZones({ {
        id = "stui_pin_badge", ges = "tap",
        screen_zone = { ratio_x = 0.6, ratio_y = 0.75, ratio_w = 0.4, ratio_h = 0.25 },
        overrides = { "bos_toolbar_tap", "bos_toolbar_bottom_tap", "bos_toolbar_bottom_ext_tap",
            "tap_forward", "tap_backward", "readerfooter_tap", "tap_right_bottom_corner" },
        handler = function(ges)
            local r = live[ui] and live[ui].badge
            if r and ges.pos.x >= r.x and ges.pos.x < r.x + r.w and ges.pos.y >= r.y and ges.pos.y < r.y + r.h then
                M.showDrawer(ui)
                return true
            end
            return false
        end,
    } })
end

function M.detach(ui) live[ui] = nil end

-- page thumbnails are drawn in a forked process: no badge in them
function M.install()
    if M._installed then return end
    M._installed = true
    pcall(function()
        local RT = require("apps/reader/modules/readerthumbnail")
        local orig = RT._getPageImage
        RT._getPageImage = function(self, ...)
            M.in_thumbnail = true
            return orig(self, ...)
        end
    end)
end

-- ---------------------------------------------------------------- the drawer

local Drawer = InputContainer:extend{
    name = "stui_pins_drawer",
    ui = nil,
    index = 1,
}

function Drawer:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.pins = M.list(self.ui)
    self.index = math.max(1, math.min(#self.pins, self.index or 1))
    self.w = math.max(S(300), math.floor(W * 0.62))
    self.x = W - self.w
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.panel = Geom:new{ x = self.x - Look.SHADOW, y = 0, w = self.w + Look.SHADOW, h = H }
    local all = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events = {
        DrawerTap = { GestureRange:new{ ges = "tap", range = all } },
        DrawerSwipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self.thumbs = {}
    self:requestThumb()
end

function Drawer:pageBox()
    local pad = S(14)
    local bw = self.w - 2 * pad - Look.SHADOW
    local bh = Screen:getHeight() - S(52) - 2 * pad - S(52) - S(12) - S(52) - S(14) - S(12)
    return pad, bw, bh
end

function Drawer:requestThumb()
    local pin = self.pins[self.index]
    local th = self.ui.thumbnail
    if not (pin and th) then return end
    local _pad, bw, bh = self:pageBox()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local tw, tht = bw - 2 * Look.LINE, math.floor((bw - 2 * Look.LINE) * H / W)
    if tht > bh - 2 * Look.LINE then
        tht = bh - 2 * Look.LINE
        tw = math.floor(tht * W / H)
    end
    self.tw, self.th = tw, tht
    if self.thumbs[pin.page] ~= nil then return end
    pcall(function()
        th:getPageThumbnail(pin.page, tw, tht, "stui_pins", function(tile, _b, async)
            if self.closed then return end
            self.thumbs[pin.page] = tile or false
            if async then UIManager:setDirty(self, "ui", self.panel) end
        end)
    end)
end

function Drawer:paintTo(bb, x, y)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local px = self.x
    if Look.theme.shadow ~= "none" then bb:paintRect(px - Look.SHADOW, 0, Look.SHADOW, H, Look.theme.shade) end
    bb:paintRect(px, 0, self.w, H, WHITE)
    bb:paintRect(px, 0, Look.LINE, H, Look.INK)
    self.rects = {}
    -- ‹ [PIN 1 OF 2] › ×
    local hy, hh = S(8), S(36)
    local kw = S(40)
    local function key(name, kx, label, enabled)
        local r = Look.button(bb, kx, hy, kw, hh, label, { enabled = enabled, size = 16 })
        self.rects[name] = r
    end
    key("prev", px + S(12), "\u{2039}", self.index > 1)
    local cx = px + S(12) + kw + Look.SHADOW_SMALL + S(10)
    local close_w = S(36)
    local nx = px + self.w - S(12) - close_w - S(8) - kw - Look.SHADOW_SMALL
    key("next", nx, "\u{203A}", self.index < #self.pins)
    Look.stripes(bb, cx, hy + S(8), nx - S(10) - cx, hh - S(16))
    local cap = require("bos_look").case(T(_("Pin %1 of %2"), self.index, #self.pins))
    local capw = Look.textWidth(cap, 11) + S(16)
    local capx = cx + math.floor((nx - S(10) - cx - capw) / 2)
    Look.box(bb, capx, hy + S(6), capw, hh - S(12))
    Look.label(bb, cap, capx, hy + S(6), capw, hh - S(12), 11, { align = "center" })
    local clx = px + self.w - S(12) - close_w
    Look.label(bb, "\u{00D7}", clx, hy, close_w, hh, 20, { align = "center" })
    self.rects.close = Geom:new{ x = clx - S(6), y = 0, w = close_w + S(18), h = hh + S(16) }
    bb:paintRect(px, hy + hh + S(8), self.w, Look.LINE, BLACK)
    -- the page
    local pin = self.pins[self.index]
    local pad, bw, bh = self:pageBox()
    local by = hy + hh + S(8) + Look.LINE + pad
    Look.box(bb, px + pad, by, bw, bh, { shadow = Look.SHADOW })
    local tile = pin and self.thumbs[pin.page]
    if tile and tile.bb then
        local tbw, tbh = tile.bb:getWidth(), tile.bb:getHeight()
        bb:blitFrom(tile.bb, px + pad + math.floor((bw - tbw) / 2), by + math.floor((bh - tbh) / 2), 0, 0,
            math.min(tbw, bw - 2 * Look.LINE), math.min(tbh, bh - 2 * Look.LINE))
    else
        local lh = math.max(S(8), math.floor(bh / 22))
        for ly = by + S(16), by + bh - S(16), lh do
            bb:paintRect(px + pad + S(16), ly, bw - S(32), math.max(1, S(1.5)), Look.LIGHT)
        end
    end
    if pin then
        local chip = require("bos_look").case(T(_("Page %1"), pin.page))
        local cw = Look.textWidth(chip, 10) + S(14)
        Look.box(bb, px + pad + S(8), by + bh - S(8) - S(22), cw, S(22))
        Look.label(bb, chip, px + pad + S(8), by + bh - S(8) - S(22), cw, S(22), 10, { align = "center" })
    end
    -- GO TO PAGE · FULL SCREEN, then UNPIN
    local ry = by + bh + Look.SHADOW + S(14)
    local half = math.floor((bw - S(12)) / 2)
    self.rects.go = Look.button(bb, px + pad, ry, half, S(42), _("Go to page"), { size = 12 })
    self.rects.full = Look.button(bb, px + pad + half + S(12), ry, half, S(42), _("Full screen"), { size = 12 })
    ry = ry + S(42) + S(14)
    self.rects.unpin = Look.button(bb, px + pad, ry, bw, S(42), _("Unpin"), { size = 12, on = true })
end

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function Drawer:go(i)
    if i < 1 or i > #self.pins then return end
    self.index = i
    self:requestThumb()
    UIManager:setDirty(self, "ui", self.panel)
end

function Drawer:onDrawerTap(_, ges)
    local pos = ges.pos
    if pos.x < self.x - Look.SHADOW then self:onClose() return true end
    local r = self.rects or {}
    local pin = self.pins[self.index]
    if inside(pos, r.close) then self:onClose()
    elseif inside(pos, r.prev) then self:go(self.index - 1)
    elseif inside(pos, r.next) then self:go(self.index + 1)
    elseif inside(pos, r.go) and pin then
        local ui = self.ui
        self:onClose()
        pcall(function() ui.link:addCurrentLocationToStack() end)
        ui:handleEvent(require("ui/event"):new("GotoPage", pin.page))
    elseif inside(pos, r.full) and pin then
        self:fullScreen(pin.page)
    elseif inside(pos, r.unpin) and pin then
        M.remove(self.ui, pin.page)
        self.pins = M.list(self.ui)
        if #self.pins == 0 then self:onClose() return true end
        self.index = math.min(self.index, #self.pins)
        self:requestThumb()
        UIManager:setDirty(self, "ui", self.panel)
    end
    return true
end

function Drawer:onDrawerSwipe(_, ges)
    if ges.direction == "west" then self:go(self.index + 1)
    elseif ges.direction == "east" then
        if ges.pos.x < self.x + S(40) then self:onClose() else self:go(self.index - 1) end
    end
    return true
end

--- The page at the size of the screen, in KOReader's image viewer (zoom, pan).
function Drawer:fullScreen(page)
    local th = self.ui.thumbnail
    if not th then return end
    local W, H = Screen:getWidth(), Screen:getHeight()
    pcall(function()
        th:getPageThumbnail(page, W, H, "stui_pins_full", function(tile)
            if not (tile and tile.bb) then return end
            local ImageViewer = require("ui/widget/imageviewer")
            UIManager:show(ImageViewer:new{ image = tile.bb:copy(), image_disposable = true,
                with_title_bar = false, fullscreen = true })
        end)
    end)
end

function Drawer:onShow()
    UIManager:setDirty(self, "ui", self.panel)
    return true
end

function Drawer:onCloseWidget()
    self.closed = true
    UIManager:setDirty(self.ui, "ui", self.panel)
end

function Drawer:onClose()
    UIManager:close(self)
    return true
end

function M.showDrawer(ui, index)
    if #raw(ui) == 0 then return end
    UIManager:show(Drawer:new{ ui = ui, index = index or 1 })
end

--- PIN in KOReader's highlight menu: pins the page of the selection.
function M.installHighlightButton(ui)
    if not (ui and ui.highlight and ui.highlight.addToHighlightDialog) then return end
    ui.highlight:addToHighlightDialog("12_stui_pin", function(this)
        return {
            text = _("Pin page"),
            callback = function()
                pcall(function()
                    local page = ui:getCurrentPage()
                    if ui.paging and this.hold_pos and this.hold_pos.page then page = this.hold_pos.page end
                    M.add(ui, page)
                end)
                pcall(function() this:onClose() end)
                pcall(function() require("ui/widget/notification"):notify(_("Page pinned")) end)
            end,
        }
    end)
end

return M
