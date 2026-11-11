--[[
ShelfTechUI's status line: the same row on the reading toolbar, in Quick
Settings, on the reading summary and in the Settings app.

    11:32 AM                                ☀ 50%   (wifi)   ▭▮ 87%

  time      as text
  light     a sun, and the brightness (only on devices with a frontlight)
  Wi-Fi     a Wi-Fi fan: black when connected, grey and struck through when
            off or not connected
  battery   a battery whose fill follows the charge (a bolt while charging),
            and the percentage

The icons are drawn here, pixel by pixel, so they show on every device
whatever fonts it has.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local Widget = require("ui/widget/widget")

local UI = require("bos_ui")
local S = UI.S
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY_9
local HAIR = Blitbuffer.COLOR_LIGHT_GRAY

local M = {}

-- ---------------------------------------------------------------------------
-- Device state (Wi-Fi asked at most every few seconds: it can be slow)
-- ---------------------------------------------------------------------------

local _net = { t = 0 }

function M.state()
    local st = {}
    local p = Device:getPowerDevice()
    if Device:hasBattery() then
        pcall(function()
            st.batt = p:getCapacity()
            st.charging = p:isCharging()
        end)
    end
    if Device:hasFrontlight() then
        pcall(function()
            local lo, hi = p.fl_min or 0, p.fl_max or 100
            local v = p:isFrontlightOn() and p:frontlightIntensity() or lo
            st.light = math.floor((v - lo) / math.max(1, hi - lo) * 100 + 0.5)
        end)
    end
    if Device:hasWifiToggle() or Device:isEmulator() then
        local now = os.time()
        if now - _net.t >= 4 then
            _net.t = now
            local ok = pcall(function()
                local NM = require("ui/network/manager")
                _net.on = NM:isWifiOn() and true or false
                _net.connected = _net.on and NM:isConnected() and true or false
                _net.ssid = nil
                if _net.connected then
                    local nw = NM:getCurrentNetwork()
                    _net.ssid = type(nw) == "table" and nw.ssid or NM.lease_ssid
                end
            end)
            if not ok then _net.on, _net.connected = false, false end
        end
        st.wifi_shown = true
        st.wifi_on, st.connected, st.ssid = _net.on, _net.connected, _net.ssid
    end
    return st
end

function M.invalidate() _net.t = 0 end

-- Wi-Fi in between: turning on takes a few seconds and joining a network a
-- few more, and until it's done the device only says "on, not connected".
-- So what was asked for is remembered for a while, and shown as it happens
-- (as a phone does): Turning on… → Connecting… → the network's name.
local _want = nil -- { on = bool, at = time }
local SETTLE = 40

--- Wi-Fi was just asked to go on (true) or off (false).
function M.wifiAsked(on)
    _want = { on = on and true or false, at = os.time() }
    _net.t = 0
end

--- "off" | "turning_on" | "connecting" | "connected" | "idle" (on, not
--- connected, nothing asked) | "turning_off", and the network's name.
function M.wifiPhase()
    if _want and os.time() - _want.at > SETTLE then _want = nil end
    -- asked afresh only while it's in between (asking can be slow on a
    -- Kindle; otherwise what was learnt in the last few seconds will do)
    if _want then _net.t = 0 end
    local st = M.state()
    if _want then
        if _want.on then
            if st.connected then _want = nil return "connected", st.ssid end
            return st.wifi_on and "connecting" or "turning_on"
        else
            if not st.wifi_on then _want = nil return "off" end
            return "turning_off"
        end
    end
    if not st.wifi_on then return "off" end
    if st.connected then return "connected", st.ssid end
    return "idle"
end

function M.wifiBusy()
    local ph = M.wifiPhase()
    return ph == "turning_on" or ph == "connecting" or ph == "turning_off"
end

--- The phase in words.
function M.wifiText()
    local _ = require("gettext")
    local ph, ssid = M.wifiPhase()
    if ph == "off" then return _("Off") end
    if ph == "turning_on" then return _("Turning on…") end
    if ph == "connecting" then return _("Connecting…") end
    if ph == "turning_off" then return _("Turning off…") end
    if ph == "connected" then return ssid or _("Connected") end
    return _("Not connected")
end

--- Call `fn` each time the phase changes, every second while Wi-Fi is in
--- between (and once when it settles); stops by itself, or when `alive()`
--- says no. Returns a function that stops it.
function M.watchWifi(fn, alive)
    local UIManager = require("ui/uimanager")
    local last = M.wifiPhase()
    local stopped = false
    local tick
    tick = function()
        if stopped or (alive and not alive()) then return end
        local ph = M.wifiPhase()
        if ph ~= last then
            last = ph
            pcall(fn, ph)
        end
        if ph == "turning_on" or ph == "connecting" or ph == "turning_off" then
            UIManager:scheduleIn(1, tick)
        end
    end
    UIManager:scheduleIn(0.5, tick)
    return function() stopped = true UIManager:unschedule(tick) end
end

--- What the Wi-Fi tile says under its name, as Android does: the network
--- you're on, "Not connected", or "Off".
function M.wifiLine()
    if _want then return M.wifiText() end
    local st = M.state()
    if not st.wifi_on then return require("gettext")("Off") end
    if not st.connected then return require("gettext")("Not connected") end
    return st.ssid or require("gettext")("Connected")
end

-- ---------------------------------------------------------------------------
-- The icons
-- ---------------------------------------------------------------------------

--- A battery, `h` tall: outline, nub, a fill as long as the charge;
--- a lightning bolt while charging. Returns its width.
function M.battery(bb, x, y, h, level, charging, ink)
    ink = ink or BLACK
    local w = math.floor(h * 2)
    local b = math.max(1, math.floor(h / 7))
    local nub_w, nub_h = math.max(2, math.floor(h / 5)), math.floor(h / 2)
    local bw = w - nub_w
    bb:paintRect(x, y, bw, h, ink)
    bb:paintRect(x + b, y + b, bw - 2 * b, h - 2 * b, WHITE)
    bb:paintRect(x + bw, y + math.floor((h - nub_h) / 2), nub_w, nub_h, ink)
    local ix, iy, iw, ih = x + 2 * b, y + 2 * b, bw - 4 * b, h - 4 * b
    level = math.max(0, math.min(100, level or 0))
    local fw = math.floor(iw * level / 100 + 0.5)
    if level > 0 and fw < 1 then fw = 1 end
    if fw > 0 then bb:paintRect(ix, iy, fw, ih, ink) end
    if charging then
        -- a bolt, in the middle: white over the fill, black over the empty part
        local cx = x + math.floor(bw / 2)
        local bh = ih
        for i = 0, bh - 1 do
            local t = i / math.max(1, bh - 1)
            -- top half leans right, bottom half leans left, joined by a step
            local off = t < 0.5 and math.floor((0.5 - t) * ih * 0.9) or -math.floor((t - 0.5) * ih * 0.9)
            local px = cx + off - (t < 0.5 and 0 or 1)
            local pw = math.max(2, math.floor(ih / 4))
            local yy = iy + i
            local col = (px - ix) < fw and WHITE or ink
            bb:paintRect(px - math.floor(pw / 2), yy, pw, 1, col)
        end
        local my = iy + math.floor(bh / 2)
        local mw = math.max(3, math.floor(ih * 0.9))
        local col = (cx - ix) < fw and WHITE or ink
        bb:paintRect(cx - math.floor(mw / 2), my - 1, mw, math.max(2, math.floor(ih / 6)), col)
    end
    return w
end

--- A Wi-Fi fan, `s` across: a dot and two arcs. Connected: black. Otherwise:
--- grey, with a black stroke through it. Returns its width.
function M.wifi(bb, x, y, s, connected, on)
    local col = connected and BLACK or GRAY
    local cx = x + s / 2
    local cy = y + s * 0.92
    local band = math.max(1.6, s * 0.13)
    local radii = { s * 0.16, s * 0.48, s * 0.82 }
    for py = 0, s - 1 do
        for px = 0, s - 1 do
            local dx = (x + px + 0.5) - cx
            local dy = cy - (y + py + 0.5)
            if dy > -0.5 then
                local r = math.sqrt(dx * dx + dy * dy)
                local inside_angle = math.abs(dx) <= dy + 0.5
                local hit = r <= radii[1]
                if not hit and inside_angle then
                    for k = 2, 3 do
                        if r >= radii[k] - band and r <= radii[k] then hit = true break end
                    end
                end
                if hit then bb:paintRect(x + px, y + py, 1, 1, col) end
            end
        end
    end
    if not connected then
        local t = math.max(1, math.floor(s / 10))
        for i = 0, s - 1 do
            bb:paintRect(x + i, y + i, t + 1, 1, WHITE)
            bb:paintRect(x + i, y + i + t, t + 1, 1, BLACK)
        end
    end
    return s
end

--- A sun: a disc and eight rays. Returns its width.
function M.sun(bb, x, y, s, ink)
    ink = ink or BLACK
    local c = s / 2
    local r_disc = s * 0.22
    local r1, r2 = s * 0.34, s * 0.5
    local t = math.max(1, s * 0.07)
    for py = 0, s - 1 do
        for px = 0, s - 1 do
            local dx, dy = px + 0.5 - c, py + 0.5 - c
            local r = math.sqrt(dx * dx + dy * dy)
            local hit = r <= r_disc
            if not hit and r >= r1 and r <= r2 then
                -- on one of the eight rays?
                local ax, ay = math.abs(dx), math.abs(dy)
                if ax <= t or ay <= t or math.abs(ax - ay) <= t * 1.2 then hit = true end
            end
            if hit then bb:paintRect(x + px, y + py, 1, 1, ink) end
        end
    end
    return s
end

-- ---------------------------------------------------------------------------
-- The row
-- ---------------------------------------------------------------------------

local Row = Widget:extend{ width = nil, hairline = true, color = BLACK, no_wifi = false }
M.Row = Row

function Row:init()
    self.face = UI.face(15)
    self.line_h = S(26)
    self.height = self.line_h + (self.hairline and S(8) or 0)
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function Row:getSize() return Geom:new{ w = self.width, h = self.height } end
function Row:free() end

local function txt(bb, s, face, x, y, h, color)
    local t = TextWidget:new{ text = s, face = face, fgcolor = color }
    local sz = t:getSize()
    t:paintTo(bb, x, y + math.floor((h - sz.h) / 2))
    t:free()
    return sz.w
end

local function txtW(s, face)
    local t = TextWidget:new{ text = s, face = face }
    local w = t:getSize().w
    t:free()
    return w
end

function Row:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local h = self.line_h
    local st = M.state()
    local datetime = require("datetime")
    local clock = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    txt(bb, clock, self.face, x, y, h, self.color)
    -- right side, laid out right to left
    local gap = S(16)
    local icon = S(16)
    local rx = x + self.width
    if st.batt then
        local pct = st.batt .. "%"
        rx = rx - txtW(pct, self.face)
        txt(bb, pct, self.face, rx, y, h, self.color)
        local bh = S(12)
        local bw = math.floor(bh * 2)
        rx = rx - S(5) - bw
        M.battery(bb, rx, y + math.floor((h - bh) / 2), bh, st.batt, st.charging)
        rx = rx - gap
    end
    if st.wifi_shown and not self.no_wifi then
        rx = rx - icon
        M.wifi(bb, rx, y + math.floor((h - icon) / 2), icon, st.connected, st.wifi_on)
        rx = rx - gap
    end
    if st.light then
        local pct = st.light .. "%"
        rx = rx - txtW(pct, self.face)
        txt(bb, pct, self.face, rx, y, h, self.color)
        rx = rx - S(4) - icon
        M.sun(bb, rx, y + math.floor((h - icon) / 2), icon)
    end
    if self.hairline then
        bb:paintRect(x, y + h + S(3), self.width, math.max(1, S(1.5)), HAIR)
    end
end

--- The status row, `width` wide.
function M.row(width, opts)
    opts = opts or {}
    return Row:new{ width = width, hairline = opts.hairline ~= false }
end

--- Use ShelfTechUI's icon row (true), or Bookshelf's own status line.
function M.enabled()
    local ok, v = pcall(function() return require("bos_settings_store").get("status_icons") end)
    return not ok or v ~= false
end

return M
