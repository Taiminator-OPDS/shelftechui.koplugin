--[[
Quick Settings (in a book): swipe down from the top of the page, or tap the
status line on the reading toolbar. A panel drops from the top, Kindle-style:

    6:42 PM                              82%  ⌔        ← Bookshelf's status line
    ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
    │  ⌔   │ │  ◐   │ │  ⟳   │ │  ↻   │                ← tap: toggle / act
    │WI-FI │ │NIGHT │ │ROTATE│ │REFRESH│                  hold Wi-Fi: networks
    └──────┘ └──────┘ └──────┘ └──────┘
    BRIGHTNESS
    ☼ [−] ━━━━━━━━●━━━━━━━ [+]  50%
    WARMTH
    🌡 [−] ━━━━━━━━━━━━●━━━ [+]  70%
    ─────────────────────────────────
    All settings                    ›

The tiles, their order and what holding each does are chosen in Settings →
ShelfTechUI → Quick Settings (bos_controls); so are the two sliders, and
whether swiping down opens this panel at all. Tap outside it, swipe up, or
press Back to close.
--]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")

local UI = require("bos_ui")
local S, BLACK, WHITE = UI.S, UI.BLACK, UI.WHITE
local Screen = Device.screen

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function wifiOn()
    local ok, on = pcall(function() return require("ui/network/manager"):isWifiOn() end)
    return ok and on
end

-- ---------------------------------------------------------------------------
-- The tiles (which ones, their order and their long-press: bos_controls)
-- ---------------------------------------------------------------------------

local Controls = require("bos_controls")
local PER_ROW = 4

local function glyphOf(c)
    local g = c.glyph
    if type(g) == "function" then return g() end
    return g
end

-- (a repaint scheduled for later does nothing once the panel has closed)
local function QuickSettingsLive(panel)
    if not panel then return true end
    for _i, e in ipairs(UIManager._window_stack) do if e.widget == panel then return true end end
    return false
end

local TileGrid = InputContainer:extend{ width = nil, items = nil, panel = nil }

function TileGrid:init()
    self.gap = S(12)
    self.tile_w = math.floor((self.width - (PER_ROW - 1) * self.gap) / PER_ROW)
    self.sh = require("bos_look").SHADOW_SMALL
    self.tile_w = math.floor((self.width - self.sh - (PER_ROW - 1) * self.gap) / PER_ROW)
    self.tile_h = S(84)
    self.rows = math.max(1, math.ceil(#self.items / PER_ROW))
    self.height = self.rows * self.tile_h + (self.rows - 1) * self.gap + self.sh
    self.f_label, self.label_bold = UI.boldFace(12)
    self.f_sub = UI.face(11)
    self.glyph_pt = UI.ptForPx(S(28))
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local range = function() return self.dimen end
    self.ges_events = {
        TapTile = { GestureRange:new{ ges = "tap", range = range } },
        HoldTile = { GestureRange:new{ ges = "hold", range = range } },
    }
end

function TileGrid:getSize() return Geom:new{ w = self.width, h = self.height } end

function TileGrid:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local h = self.tile_h
    for i, c in ipairs(self.items) do
        local col, row = (i - 1) % PER_ROW, math.floor((i - 1) / PER_ROW)
        local tx = x + col * (self.tile_w + self.gap)
        local ty = y + row * (h + self.gap)
        local on = self.pressed == c
        if not on and c.active then
            local ok, v = pcall(c.active)
            on = ok and v and true or false
        end
        local ink = on and WHITE or BLACK
        -- a square tile on a hard shadow; pressed: pushed onto it
        local Look = require("bos_look")
        local down = self.pressed == c
        if down then tx, ty = tx + self.sh, ty + self.sh end
        Look.box(bb, tx, ty, self.tile_w, h, { fill = on and BLACK or WHITE, shadow = down and 0 or self.sh })
        local sub
        if c.qs and c.qs.sub then
            local ok, v = pcall(c.qs.sub)
            if ok and v and v ~= "" then sub = v end
        end
        local glyph = glyphOf(c)
        if glyph then
            local g = TextWidget:new{ text = glyph, face = UI.symbolFace(self.glyph_pt), fgcolor = ink }
            local gs = g:getSize()
            g:paintTo(bb, tx + math.floor((self.tile_w - gs.w) / 2), ty + (sub and S(6) or S(12)))
            g:free()
        end
        if sub then
            -- name, and under it what it's on (the network, as on Android)
            Look.label(bb, c.name, tx + S(4), ty + h - S(42), self.tile_w - S(8), S(20), 12,
                { align = "center", color = ink })
            UI.drawTextCentered(bb, sub, self.f_sub, tx + S(6), ty + h - S(24), self.tile_w - S(12), S(18), ink)
        else
            Look.label(bb, c.name, tx + S(4), ty + h - S(32), self.tile_w - S(8), S(24), 12,
                { align = "center", color = ink })
        end
        if down then tx, ty = tx - self.sh, ty - self.sh end
        c._qs_rect = Geom:new{ x = tx, y = ty, w = self.tile_w + self.sh, h = h + self.sh }
    end
end

--- Repaint the grid; `rect` (one tile) limits the screen refresh to it, and
--- `kind` "fast" is the quick black-and-white refresh for a press.
function TileGrid:repaint(rect, kind)
    if not (self.dimen and self.dimen.x) then return end
    if not QuickSettingsLive(self.panel) then return end
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, kind or "ui", rect or self.dimen)
end

function TileGrid:tileAt(pos)
    for _i, c in ipairs(self.items) do
        if inside(pos, c._qs_rect) then return c end
    end
end

function TileGrid:ctx()
    local panel = self.panel
    return { close = function(fn) panel:closeThen(fn) end }
end

--- A tile pressed: drawn pushed down and shown at once (fast refresh), so the
--- finger gets an answer before whatever the tile does.
function TileGrid:flash(c)
    self.pressed = c
    self:repaint(c._qs_rect, "fast")
    UIManager:forceRePaint()
    self.pressed = nil
end

--- After the action: the tile lifts again, its own square only; a tile that
--- shows a state that takes a while to settle (Wi-Fi) looks once more.
function TileGrid:after(c)
    local Status = require("bos_status")
    local function again()
        if c.id == "wifi" then Status.invalidate() end
        self:repaint(c._qs_rect)
    end
    again()
    if c.id == "wifi" then
        -- Turning on… → Connecting… → the network's name, each as it happens
        -- (bos_status.watchWifi: every second until it settles, then stops)
        if self._wifi_stop then self._wifi_stop() end
        self._wifi_stop = Status.watchWifi(again, function() return QuickSettingsLive(self.panel) end)
    elseif c.slow then
        UIManager:scheduleIn(2, again)
    end
end

function TileGrid:onTapTile(_, ges)
    local c = self:tileAt(ges.pos)
    if not c then return false end
    if c.id == "wifi" then
        -- say where it's going before it gets there
        pcall(function()
            local on = require("ui/network/manager"):isWifiOn()
            require("bos_status").wifiAsked(not on)
        end)
    end
    self:flash(c)
    UIManager:nextTick(function()
        Controls.tap("qs", c, self:ctx())
        if not c.qs.closes then self:after(c) end
    end)
    return true
end

function TileGrid:onHoldTile(_, ges)
    local c = self:tileAt(ges.pos)
    if not c then return false end
    self:flash(c)
    UIManager:nextTick(function()
        if not Controls.hold("qs", c, self:ctx()) then self:repaint(c._qs_rect) end
    end)
    return true
end

-- Without Bookshelf: date left; battery and time right; a grey hairline.
local FallbackStatus = require("ui/widget/widget"):extend{ width = nil }

function FallbackStatus:init()
    self.height = S(30)
    self.f = UI.face(16)
end

function FallbackStatus:getSize() return Geom:new{ w = self.width, h = self.height + S(8) } end

function FallbackStatus:paintTo(bb, x, y)
    local datetime = require("datetime")
    local right = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    if Device:hasBattery() then
        local ok, lvl = pcall(function() return Device:getPowerDevice():getCapacity() end)
        if ok and type(lvl) == "number" then right = lvl .. "%   " .. right end
    end
    local rw = UI.textWidth(right, self.f)
    UI.drawText(bb, os.date("%A %d %B"), self.f, x, y, self.height, BLACK, self.width - rw - S(16))
    UI.drawText(bb, right, self.f, x + self.width - rw, y, self.height, BLACK)
    bb:paintRect(x, y + self.height + S(2), self.width, math.max(1, S(1.5)), UI.LIGHT)
end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

local QuickSettings = InputContainer:extend{
    name = "bookshelfos_quicksettings",
    covers_header = true,
}

function QuickSettings:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.pad = UI.sidePad()
    self.shadow = S(3)
    local w = W - 2 * self.pad
    local rows = VerticalGroup:new{ align = "left" }
    local status = UI.buildStatusRow(w, self.file) or FallbackStatus:new{ width = w }
    -- the Wi-Fi tile says it all here: no Wi-Fi icon in the status line
    if status.line_h then status.no_wifi = true end
    table.insert(rows, VerticalSpan:new{ width = self.pad })
    table.insert(rows, status)
    table.insert(rows, VerticalSpan:new{ width = S(14) })
    local shown = Controls.shown("qs")
    if #shown > 0 then
        table.insert(rows, TileGrid:new{ width = w, items = shown, panel = self })
        table.insert(rows, VerticalSpan:new{ width = S(10) })
    end
    local Store = require("bos_settings_store")
    if UI.Light.hasBrightness() and Store.get("qs_brightness") ~= false then
        table.insert(rows, UI.MenuTitle:new{ width = w, text = _("Brightness") })
        table.insert(rows, UI.LightSlider:new{ kind = "brightness", width = w })
    end
    if UI.Light.hasWarmth() and Store.get("qs_warmth") ~= false then
        table.insert(rows, UI.MenuTitle:new{ width = w, text = _("Warmth") })
        table.insert(rows, UI.LightSlider:new{ kind = "warmth", width = w })
    end
    table.insert(rows, VerticalSpan:new{ width = S(10) })
    table.insert(rows, UI.ButtonRow:new{ width = w, menu = self, text = _("All settings"),
        callback = function() require("bos_settings").open() end })
    table.insert(rows, VerticalSpan:new{ width = S(10) })
    self.rows = rows
    -- our child, so its rows (tiles, sliders, the settings row) get the gestures
    self[1] = rows
    self.panel_h = rows:getSize().h
    self.panel = Geom:new{ x = 0, y = 0, w = W, h = self.panel_h }

    local range = function() return self.dimen end
    self.ges_events = {
        QSTap = { GestureRange:new{ ges = "tap", range = range } },
        QSSwipe = { GestureRange:new{ ges = "swipe", range = range } },
        QSHold = { GestureRange:new{ ges = "hold", range = range } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
end

function QuickSettings:region()
    return Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.panel_h + UI.line() + self.shadow }
end

function QuickSettings:paintTo(bb, x, y)
    local W = self.dimen.w
    local Look = require("bos_look")
    bb:paintRect(0, 0, W, self.panel_h + UI.line(), Look.PAPER)
    self.rows:paintTo(bb, self.pad, 0)
    -- panel edge, as the reading toolbar's (Retro: a black rule and a hard shadow)
    Look.edge(bb, 0, self.panel_h + UI.line(), W, 1, self.shadow)
end

function QuickSettings:onShow()
    UIManager:setDirty(self, function() return "ui", self:region() end)
    return true
end

function QuickSettings:onCloseWidget()
    local r = self:region()
    UIManager:setDirty(nil, function() return "ui", r end)
    if QuickSettings.live == self then QuickSettings.live = nil end
end

--- Close, let the page repaint, then run fn.
function QuickSettings:closeThen(fn)
    UIManager:close(self)
    UIManager:nextTick(function()
        pcall(function() UIManager:forceRePaint() end)
        local ok, err = pcall(fn)
        if not ok then logger.warn("ShelfTechUI: quick setting failed:", err) end
    end)
end

function QuickSettings:onQSTap(_, ges)
    if not inside(ges.pos, self.panel) then UIManager:close(self) end
    return true
end

function QuickSettings:onQSSwipe(_, ges)
    if ges.direction == "north" or not inside(ges.pos, self.panel) then UIManager:close(self) end
    return true
end

function QuickSettings:onQSHold() return true end
function QuickSettings:onClose() UIManager:close(self) return true end

local M = { Panel = QuickSettings }

--- Show Quick Settings (toggles it if already shown).
function M.show()
    if QuickSettings.live then
        UIManager:close(QuickSettings.live)
        return
    end
    local file
    pcall(function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local ui = ReaderUI and ReaderUI.instance
        file = ui and ui.document and ui.document.file
    end)
    local panel = QuickSettings:new{ file = file }
    QuickSettings.live = panel
    UIManager:show(panel)
    return panel
end

return M
