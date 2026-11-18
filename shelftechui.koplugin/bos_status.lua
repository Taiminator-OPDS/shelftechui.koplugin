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

local function now()
    local ok, t = pcall(function() return require("socket").gettime() end)
    return ok and t or os.time()
end

-- what the device last said about Wi-Fi, and when (t); `ssid_t`: when the
-- network's name was last asked for (on a Kindle that's a call to the
-- system's Wi-Fi service, which can stall while it's busy: so rarely)
local _net = { t = 0, ssid_t = 0 }
local MAX_AGE, MAX_AGE_BUSY = 4, 0.75

-- A Kindle can keep its Wi-Fi interface loaded after the radio is switched
-- off, so "the interface is there" (how KOReader asks) reads as on. The
-- Kindle's own switch, the one KOReader sets to turn it off, says. nil:
-- not a Kindle, or it couldn't be asked.
local kindle_lipc
local function kindleRadio()
    if not Device:isKindle() then return nil end
    if kindle_lipc == nil then
        local ok, lipc = pcall(require, "liblipclua")
        kindle_lipc = ok and lipc or false
    end
    if not kindle_lipc then return nil end
    local v
    pcall(function()
        local h = kindle_lipc.init("com.github.koreader.shelftechui")
        if h then
            v = h:get_int_property("com.lab126.cmd", "wirelessEnable")
            h:close()
        end
    end)
    if v == nil then return nil end
    return v == 1
end

local function readNet(max_age)
    if now() - _net.t < max_age then return end
    _net.t = now()
    local ok = pcall(function()
        local NM = require("ui/network/manager")
        local was = _net.connected
        _net.on = NM:isWifiOn() and true or false
        if _net.on and kindleRadio() == false then _net.on = false end
        _net.connected = _net.on and NM:isConnected() and true or false
        if not _net.connected then
            _net.ssid, _net.ssid_tries = nil, 0
        elseif type(NM.lease_ssid) == "string" and NM.lease_ssid ~= "" then
            -- (what KOReader learnt when it joined: costs nothing)
            _net.ssid = NM.lease_ssid
        elseif not _net.ssid then
            -- just joined, the device may not say the name yet (a Kindle
            -- answers "" for a moment): asked again every few seconds, then
            -- once a minute if it never does
            local wait = (_net.ssid_tries or 0) < 15 and 2 or 60
            if not was or now() - _net.ssid_t >= wait then
                _net.ssid_t = now()
                _net.ssid_tries = (_net.ssid_tries or 0) + 1
                local nw = NM:getCurrentNetwork()
                local name = type(nw) == "table" and nw.ssid or nil
                _net.ssid = (type(name) == "string" and name ~= "") and name or nil
            end
        end
    end)
    if not ok then _net.on, _net.connected, _net.ssid = false, false, nil end
end

local _want = nil -- { on = bool, at = time, acted = bool } (below)

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
        -- (looked at more often while it's in between)
        readNet(_want and MAX_AGE_BUSY or MAX_AGE)
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
local SETTLE = 40

--- Wi-Fi was just asked to go on (true) or off (false).
function M.wifiAsked(on)
    _want = { on = on and true or false, at = os.time() }
    _net.t = 0
    M.watchHome()
end

--- "off" | "turning_on" | "connecting" | "connected" | "idle" (on, not
--- connected, nothing asked) | "turning_off", and the network's name.
function M.wifiPhase()
    if _want and os.time() - _want.at > SETTLE then _want = nil end
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

--- Whether Wi-Fi is on, or on its way there (what a switch for it shows).
function M.wifiWanted()
    local ph = M.wifiPhase()
    return ph ~= "off" and ph ~= "turning_off"
end

--- Turn Wi-Fi on (true), off (false), or the other way from what it shows
--- (nil). Says so at once (wifiAsked) and does it on the next tick.
---
--- On a Kindle or a Kobo, on goes the way KOReader brings Wi-Fi back after a
--- sleep: the radio is switched on and the device joins the network it
--- knows by itself, while KOReader watches for the connection in the
--- background. (KOReader's own toggle scans for networks first, and the
--- scan holds the screen still for several seconds on a Kindle.) If no
--- network is joined, Wi-Fi goes off again after a while and a note says
--- to hold the control to choose one.
function M.toggleWifi(on)
    if on == nil then
        -- (a tile asks first, to be drawn the new way before it acts)
        if _want and not _want.acted and os.time() - _want.at <= 3 then on = _want.on
        else on = not M.wifiWanted() end
    end
    if not (_want and not _want.acted and _want.on == on) then M.wifiAsked(on) end
    if _want then _want.acted = true end
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        local ok, err = pcall(function()
            local NM = require("ui/network/manager")
            local Event = require("ui/event")
            if on then
                if NM:isWifiOn() and NM:isConnected() then return end
                if Device:hasWifiRestore() and NM.restoreWifiAsync and NM.scheduleConnectivityCheck
                        and not NM.pending_connection then
                    UIManager:broadcastEvent(Event:new("NetworkConnecting"))
                    NM:restoreWifiAsync()
                    if NM.pending_connectivity_check then NM:unscheduleConnectivityCheck() end
                    NM:scheduleConnectivityCheck()
                    M.noteIfNotJoined()
                elseif not NM:isWifiOn() then
                    UIManager:broadcastEvent(Event:new("ToggleWifi"))
                end
            else
                -- (also while it's still coming on: that's stopped)
                if not (NM:isWifiOn() or NM.pending_connectivity_check or NM.pending_connection) then return end
                if NM.disableWifi then NM:disableWifi(nil, true)
                else UIManager:broadcastEvent(Event:new("ToggleWifi")) end
            end
        end)
        if not ok then
            require("logger").warn("ShelfTechUI: Wi-Fi toggle:", err)
            _want = nil
            M.invalidate()
        end
    end)
end

--- Once Wi-Fi was turned on the quick way: if no network was joined after
--- a while, say how to choose one.
function M.noteIfNotJoined()
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(30, function()
        M.invalidate()
        local st = M.state()
        if st.connected or (_want and not _want.on) then return end
        pcall(function()
            require("ui/widget/notification"):notify(
                require("gettext")("Wi-Fi didn't join a network: hold the Wi-Fi control to choose one."))
        end)
    end)
end

--- Call `fn` each time the phase changes, every second while Wi-Fi is in
--- between (and once when it settles); stops by itself, or when `alive()`
--- says no. Returns a function that stops it.
function M.watchWifi(fn, alive)
    local UIManager = require("ui/uimanager")
    -- (the network's name counts as a change: it can come a little after
    -- the connection, and whatever shows it is drawn again then)
    local function now_is()
        local ph, ssid = M.wifiPhase()
        return ph, ph .. "|" .. tostring(ssid or ""), ssid
    end
    local _p, last = now_is()
    local stopped = false
    local nameless = 0
    local tick
    tick = function()
        if stopped or (alive and not alive()) then return end
        local ph, sig, ssid = now_is()
        if sig ~= last then
            last = sig
            pcall(fn, ph)
        end
        if ph == "turning_on" or ph == "connecting" or ph == "turning_off" then
            UIManager:scheduleIn(1, tick)
        elseif ph == "connected" and not ssid and nameless < 20 then
            -- connected, the name not known yet: looked for a while longer
            nameless = nameless + 1
            M.invalidate()
            UIManager:scheduleIn(1.5, tick)
        end
    end
    UIManager:scheduleIn(0.5, tick)
    return function() stopped = true UIManager:unschedule(tick) end
end

--- Home's toolbar follows Wi-Fi while it's in between (one watcher at a time).
local _home_stop
function M.watchHome()
    if _home_stop then _home_stop() end
    _home_stop = M.watchWifi(function()
        pcall(function() require("bos_home").sync() end)
    end)
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
