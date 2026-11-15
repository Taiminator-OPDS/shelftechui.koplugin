--[[
Transfer: send books to the device (and take files off it) from any browser
on the same Wi-Fi. A small web server of ShelfTechUI's own, inside KOReader
(bos_transfer_server), with a page in ShelfTechUI's look (transfer/index.html).
It takes the place of the FilebrowserPlus plugin (and the File Browser program
it ran), keeping its settings: the folder, the port, the timer, on at start.

  Transfer.show()        the page: a QR code, the address and a code while
                         it's on, and its few settings; opening it turns it on
  Transfer.toggle()      on / off without the page (Quick Settings, gestures)
  Transfer.isRunning()

The QR code's address signs the phone in. Typed by hand, the address asks
for the 6-digit code on the page (a new one each time Transfer is turned
on), unless "Ask for a code" is off.

The address is this device's Wi-Fi one: taken from the wireless interface
(it used to be the first address KOReader listed, which on a Kindle can be
its USB network's, so the QR code led nowhere).
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local Server = require("bos_transfer_server")
local Screen = Device.screen
local BLACK, WHITE = Look.BLACK, Look.WHITE
local S = Look.S

local M = {}

local OLD_PID_FILE = "/tmp/filebrowserplus_koreader.pid" -- FilebrowserPlus's server, if one's still running

local function exists(path) return lfs.attributes(path, "mode") ~= nil end

--- Always here: the server is part of ShelfTechUI.

-- ---------------------------------------------------------------- settings

local function get(key, default)
    local v = G_reader_settings:readSetting("FilebrowserPlus_" .. key)
    if v == nil then return default end
    return v
end
local function set(key, value) G_reader_settings:saveSetting("FilebrowserPlus_" .. key, value) end

function M.port() return tonumber(get("port", 8080)) or 8080 end
function M.folder()
    local f = get("dataPath", nil)
    if f and f ~= "" then return f end
    return G_reader_settings:readSetting("home_dir") or require("apps/filemanager/filemanagerutil").getDefaultDir()
end
function M.autoStop() return tonumber(get("auto_stop_minutes", 30)) or 30 end
function M.noPassword() return get("allow_no_password", false) == true end

-- ---------------------------------------------------------------- the address

--- This device's address on the Wi-Fi: the wireless interface's IPv4 (the
--- first, when it has several), else any interface that isn't the USB
--- network's. Asked at most every 5 s.
local ip_cache = { at = 0 }
function M.ip()
    if os.time() - ip_cache.at < 5 and ip_cache.at > 0 then return ip_cache.ip end
    local best, other
    local ok, err = pcall(function()
        local NetInfo = require("ffi/netinfo")
        local ni = NetInfo:new()
        local list = ni:retrieve()
        ni:free()
        for _i, iface in ipairs(list) do
            local v4 = iface.ipv4 and iface.ipv4:match("^([%d%.]+)")
            if v4 and v4 ~= "127.0.0.1" and not v4:match("^169%.254%.") then
                local name = tostring(iface.name or "")
                if iface.wireless or name:match("^wlan") or name:match("^wl") then
                    best = best or v4
                elseif not name:match("^usb") and not name:match("^rndis") and not name:match("^lo") then
                    other = other or v4
                end
            end
        end
    end)
    if not ok then logger.warn("ShelfTechUI: transfer address:", err) end
    ip_cache.at, ip_cache.ip = os.time(), best or other
    return ip_cache.ip
end

function M.url(with_code)
    local ip = M.ip()
    if not ip then return nil end
    local port = M.port()
    local u = "http://" .. ip .. (port == 80 and "" or (":" .. port)) .. "/"
    if with_code and M.code() then u = u .. "?k=" .. M.code() end
    return u
end

-- ---------------------------------------------------------------- the server

local code -- this time's code (nil: none asked)
function M.code() return Server.running() and code or nil end

function M.isRunning() return Server.running() ~= nil end

local function firewall(open)
    if not Device:isKindle() then return end
    local flag = open and "-A" or "-D"
    local port = M.port()
    os.execute(string.format("iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", flag, port))
    os.execute(string.format("iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", flag, port))
end

--- FilebrowserPlus's server, if one is still running from before: it holds
--- the port.
local function stopOldServer()
    local f = io.open(OLD_PID_FILE, "r")
    if not f then return end
    local pid = f:read("*n")
    f:close()
    if pid and exists("/proc/" .. pid) then
        os.execute("kill " .. pid .. " 2>/dev/null")
        for _i = 1, 10 do
            if not exists("/proc/" .. pid) then break end
            require("ffi/util").usleep(100000)
        end
        if exists("/proc/" .. pid) then os.execute("kill -9 " .. pid .. " 2>/dev/null") end
    end
    os.remove(OLD_PID_FILE)
end

local stop_at
local function autoStopCheck()
    if not M.isRunning() or not stop_at then return end
    -- never in the middle of a file coming in or going out
    if os.time() >= stop_at and not Server.busy() and os.time() - Server.lastActivity() > 30 then
        M.stop(true)
        pcall(function() require("ui/widget/notification"):notify(_("Transfer turned itself off")) end)
        return
    end
    UIManager:scheduleIn(math.min(60, math.max(5, stop_at - os.time())), autoStopCheck)
end

local function armAutoStop()
    UIManager:unschedule(autoStopCheck)
    local m = M.autoStop()
    stop_at = m > 0 and (os.time() + m * 60) or nil
    if stop_at then autoStopCheck() end
end

--- Minutes until it turns itself off (nil: it won't).
function M.minutesLeft()
    if not stop_at then return nil end
    return math.max(1, math.ceil((stop_at - os.time()) / 60))
end

-- Books that came in: home sees them (once the sending has stopped for a
-- moment, so a dozen books make one refresh, not twelve).
local received = {}
local function refreshLibrary()
    if Server.busy() then UIManager:scheduleIn(2, refreshLibrary) return end
    local n = #received
    received = {}
    pcall(function()
        local Repo = require("lib/bookshelf_book_repository")
        if Repo.invalidateWalkCache then Repo.invalidateWalkCache() end
        if Repo.invalidateLightMeta then Repo.invalidateLightMeta() end
    end)
    pcall(function() require("bos_recs").invalidate() end)
    pcall(function() require("bos_home").refresh() end)
    if n > 0 then
        pcall(function() require("ui/widget/notification"):notify(n == 1 and _("1 book received") or T(_("%1 books received"), n)) end)
    end
end

local function onReceived(path)
    table.insert(received, path)
    M.status = T(_("Received: %1"), (path:match("([^/]+)$") or path))
    if M._page then M._page:refresh("ui") end
    UIManager:unschedule(refreshLibrary)
    UIManager:scheduleIn(2, refreshLibrary)
    armAutoStop() -- (in use: the timer starts again)
end

local function onChange()
    UIManager:unschedule(refreshLibrary)
    UIManager:scheduleIn(2, refreshLibrary)
end

function M.start()
    if M.isRunning() then
        if not stop_at then armAutoStop() end
        return true
    end
    local folder = M.folder()
    if not exists(folder) then
        os.execute("mkdir -p '" .. folder:gsub("'", "'\\''") .. "'")
        if not exists(folder) then return false, T(_("The folder %1 can't be made."), folder) end
    end
    stopOldServer()
    code = nil
    if not M.noPassword() then
        math.randomseed(os.time() + math.floor(os.clock() * 1e6))
        code = string.format("%06d", math.random(0, 999999))
    end
    local device = ""
    pcall(function() device = Device.model or "" end)
    local ok, why = Server.start{ root = folder, port = M.port(), code = code, device = device,
        on_received = onReceived, on_change = onChange }
    if not ok then
        code = nil
        if why == "busy" then
            return false, T(_("Port %1 is in use by something else. Choose another in Transfer's settings."), M.port())
        end
        return false, T(_("Transfer couldn't start: %1"), tostring(why))
    end
    firewall(true)
    M.status = nil
    armAutoStop()
    logger.info("ShelfTechUI: transfer on port", M.port(), "for", folder)
    return true
end

function M.stop(quiet)
    UIManager:unschedule(autoStopCheck)
    stop_at = nil
    if M.isRunning() then
        Server.stop()
        firewall(false)
    end
    code = nil
    M.status = nil
    if not quiet then
        pcall(function() require("ui/widget/notification"):notify(_("Transfer is off")) end)
    end
    if M._page then M._page:refresh("ui") end
end

function M.toggle()
    if M.isRunning() then return M.stop() end
    local ok, why = M.start()
    local InfoMessage = require("ui/widget/infomessage")
    if not ok then
        UIManager:show(InfoMessage:new{ text = why, icon = "notice-warning" })
        return
    end
    local url = M.url()
    UIManager:show(InfoMessage:new{ timeout = 5,
        text = url and (T(_("Transfer is on.\n%1"), url) .. (M.code() and ("\n" .. T(_("Code: %1"), M.code())) or ""))
            or _("Transfer is on. Connect to Wi-Fi to use it.") })
end

--- At start: on, if it's set to be.
function M.resume()
    stopOldServer()
    if get("autostart", false) == true and not M.isRunning() then M.start() end
end

local AUTO_STOPS = { { 15, _("15 min") }, { 30, _("30 min") }, { 60, _("1 hour") }, { 0, _("Never") } }

local function pickFolder(done)
    require("bos_folders").choose(M.folder(), function(path)
        set("dataPath", path)
        done()
    end, _("Folder to share"))
end

local function askPort(done)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Port"),
        description = _("The number after the colon in the address. 8080 works everywhere; 80 (no number to type) needs a device that allows it."),
        input = tostring(M.port()), input_type = "number",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = tonumber(dlg:getInputText())
                if v and v > 0 and v < 65536 then
                    set("port", math.floor(v))
                    UIManager:close(dlg)
                    done()
                end
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

--- Changing a setting restarts a running server, so it takes effect at once.
local function apply(page, change)
    local was = M.isRunning()
    if not was then
        change()
        page:refresh("ui")
        return
    end
    -- seen at once; the restart (a second or two on an e-reader) after
    pcall(function() require("ui/widget/notification"):notify(_("Applying…")) end)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        M.stop(true)
        change()
        local ok, why = M.start()
        if not ok then
            UIManager:show(require("ui/widget/infomessage"):new{ text = why, icon = "notice-warning" })
        end
        if not page.closed then page:refresh("ui") end
    end)
end

function M.show()
    if M._page then return end
    local Page = require("bos_page")
    local InfoMessage = require("ui/widget/infomessage")
    -- opening the page is asking for it: on at once
    -- (the page shows first, "Starting…"; the server starts just after)
    local why
    local starting = not M.isRunning()

    local qr_cache = {}
    local function draw(self, bb, y, w)
        local x = self.pad
        local W = Screen:getWidth()
        local on = M.isRunning()
        local url = on and M.url(true)
        local shown = on and M.url()
        -- [ON · turns off in 28 min]                         [TURN OFF]
        local bw = S(150)
        local state = starting and _("Starting…") or (on and _("On") or _("Off"))
        local left = on and M.minutesLeft()
        if on and left then state = T(_("On · off in %1 min"), left) end
        Look.label(bb, state, x, y, w - bw - S(12), S(40), 15)
        local r = Look.button(bb, x + w - bw - Look.SHADOW_SMALL, y, bw, S(40),
            on and _("Turn off") or _("Turn on"), { size = 13, on = not on })
        self:hit(r, function()
            if M.isRunning() then M.stop(true) else
                local ok, err = M.start()
                if not ok then UIManager:show(InfoMessage:new{ text = err, icon = "notice-warning" }) end
            end
            self:refresh("ui")
        end)
        y = y + S(58)

        -- the QR card
        local card_h = S(250)
        Look.box(bb, x, y, w - Look.SHADOW, card_h, { shadow = Look.SHADOW })
        local q = S(196)
        local qx, qy = x + S(22), y + math.floor((card_h - q) / 2)
        local tx = qx + q + S(24)
        local tw = x + w - Look.SHADOW - S(18) - tx
        if url then
            if qr_cache.url ~= url then
                if qr_cache.widget then qr_cache.widget:free() end
                local ok, QRWidget = pcall(require, "ui/widget/qrwidget")
                qr_cache.widget = ok and QRWidget:new{ text = url, width = q, height = q } or nil
                qr_cache.url = url
            end
            if qr_cache.widget then qr_cache.widget:paintTo(bb, qx, qy) end
            Look.label(bb, _("Scan, or type in a browser"), tx, y + S(22), tw, S(20), 10, { color = Look.GRAY })
            Page.wrap(bb, shown, Page.serif(20, true), tx, y + S(48), tw, 3, S(28))
            Look.label(bb, _("Same Wi-Fi as this device"), tx, y + S(140), tw, S(20), 10, { color = Look.GRAY })
            if M.code() then
                -- typed in instead of scanning: the browser asks for this
                Look.label(bb, _("Code"), tx, y + S(170), tw, S(20), 10, { color = Look.GRAY })
                local big = require("ui/widget/textwidget"):new{ text = M.code(), face = Page.serif(26, true), fgcolor = BLACK }
                big:paintTo(bb, tx, y + S(192))
                big:free()
            end
            -- what's coming in
            if M.status then
                Look.label(bb, M.status, x + S(22), y + card_h - S(30), w - Look.SHADOW - S(44), S(20), 10, { keep_case = true })
            end
        else
            Look.box(bb, qx, qy, q, q, { border = Look.LINE })
            Look.fill(bb, qx + Look.LINE, qy + Look.LINE, q - 2 * Look.LINE, q - 2 * Look.LINE)
            local msg
            if starting then msg = _("Starting the server…")
            elseif not on then msg = why or _("Transfer is off. Turn it on to get an address.")
            else msg = _("No Wi-Fi address yet. Connect to Wi-Fi: the address appears here.") end
            Page.wrap(bb, msg, Page.serif(17, false, true), tx, y + S(60), tw, 5, S(26))
        end
        y = y + card_h + Look.SHADOW + S(22)

        -- settings, each one row: NAME ........ [value]
        Page.heading(bb, _("Settings"), x, y, w)
        y = y + S(30)
        local function row(name, value, fn)
            local rh = S(46)
            Look.label(bb, name, x, y, w * 0.45, rh, 12)
            local vw = math.max(S(120), Look.textWidth(Look.case(value), 12) + S(28))
            vw = math.min(vw, math.floor(w * 0.55))
            local br = Look.button(bb, x + w - vw - Look.SHADOW_SMALL, y + S(4), vw, rh - S(12), value, { size = 12 })
            self:hit(Geom:new{ x = x, y = y, w = w, h = rh }, fn)
            bb:paintRect(x, y + rh, w, 1, Look.LIGHT)
            y = y + rh + S(4)
            return br
        end
        local folder = M.folder()
        row(_("Folder shared"), #folder > 26 and ("…" .. folder:sub(-25)) or folder, function()
            pickFolder(function() apply(self, function() end) end)
        end)
        local stops = {}
        for _i, a in ipairs(AUTO_STOPS) do stops[a[1]] = a[2] end
        row(_("Turns itself off after"), stops[M.autoStop()] or T(_("%1 min"), M.autoStop()), function()
            local cur, nxt = M.autoStop(), AUTO_STOPS[1][1]
            for i, a in ipairs(AUTO_STOPS) do
                if a[1] == cur then nxt = AUTO_STOPS[i % #AUTO_STOPS + 1][1] end
            end
            set("auto_stop_minutes", nxt)
            if M.isRunning() then armAutoStop() end
            self:refresh("ui")
        end)
        row(_("Ask for a code"), M.noPassword() and _("No") or _("Yes"), function()
            if M.noPassword() then
                apply(self, function() set("allow_no_password", false) end)
                return
            end
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Without a code, anyone on this Wi-Fi who finds the address can add, download and delete files in the shared folder while Transfer is on.\n\nStop asking for a code?"),
                ok_text = _("Stop asking"),
                ok_callback = function() apply(self, function() set("allow_no_password", true) end) end,
            })
        end)
        row(_("Port"), tostring(M.port()), function()
            askPort(function() apply(self, function() end) end)
        end)
        row(_("On when KOReader starts"), get("autostart", false) == true and _("Yes") or _("No"), function()
            set("autostart", not (get("autostart", false) == true))
            self:refresh("ui")
        end)
    end

    local page
    page = Page:new{ caption = _("Transfer"), draw = draw,
        on_close = function()
            M._page = nil
            if qr_cache.widget then qr_cache.widget:free() end
        end,
        on_more = function(self, rect)
            require("bos_ui").openList({
                { text = _("About Transfer"), callback = function()
                    UIManager:show(InfoMessage:new{ text = _("Transfer is a small web server inside KOReader, on only while you want it: a browser on the same Wi-Fi can send books to the shared folder, download them and delete them. Nothing goes over the internet. It takes the place of FilebrowserPlus, keeping its folder, port and timer.") })
                end },
            }, rect)
        end }
    M._page = page
    page:show()
    -- the minutes count down while the page is open
    local function tick()
        if M._page ~= page then return end
        page:refresh("ui")
        UIManager:scheduleIn(60, tick)
    end
    UIManager:scheduleIn(60, tick)
    if starting then
        UIManager:nextTick(function()
            local ok, err = M.start()
            starting = false
            why = not ok and err or nil
            if M._page == page then page:refresh("ui") end
            if not ok and err then UIManager:show(InfoMessage:new{ text = err, icon = "notice-warning" }) end
        end)
    end
end

return M
