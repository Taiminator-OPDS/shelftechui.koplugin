--[[
Transfer: send books to the device (and take files off it) from any browser
on the same Wi-Fi, with the File Browser web server (filebrowser.org; the
binary is in transfer/). It takes over from FilebrowserPlus by Neeraj Patel
(itself derived from KOReader's filebrowser.koplugin, AGPL-3.0): the same
server, settings and saved password, on one ShelfTechUI page.

  Transfer.show(ui)      the page: a QR code and address while it's on, and
                         its few settings; opening it turns the server on
  Transfer.toggle()      on / off without the page (Quick Settings, gestures)
  Transfer.isRunning()   cheap: no process is started to find out

Compared with FilebrowserPlus:
  * one page instead of a menu row with a hidden long-press menu
  * opening the page starts the server (one tap from Quick Settings or the
    start menu) and shows the QR code at once
  * the folder is picked with KOReader's folder chooser, not typed
  * whether it's running is read from /proc, not by starting `kill` each
    time a menu is drawn; the server is reconfigured only when a setting
    changed, not on every start; nothing sleeps the interface
  * its data (password database, log) lives in koreader/settings/stui_transfer
    so a plugin update never wipes it; the log is trimmed when it grows

Settings keep FilebrowserPlus's keys, so nothing has to be set up again.
--]]

local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local Screen = Device.screen
local BLACK, WHITE = Look.BLACK, Look.WHITE
local S = Look.S

local M = {}

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".")
local BIN = PLUGIN_DIR .. "/transfer/filebrowser"
local PID_FILE = "/tmp/filebrowserplus_koreader.pid" -- FilebrowserPlus's: a server it started is ours too
local USER, DEFAULT_PASS = "admin", "admin12345678"

local function dataDir()
    local dir = DataStorage:getSettingsDir() .. "/stui_transfer"
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

local function exists(path) return lfs.attributes(path, "mode") ~= nil end

local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

--- Is the server's program here, for this device?
function M.available()
    return exists(BIN)
end

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

-- ---------------------------------------------------------------- the server

local function readPid()
    local f = io.open(PID_FILE, "r")
    if not f then return nil end
    local pid = f:read("*n")
    f:close()
    return pid
end

--- Running? (From /proc: nothing is started to find out.)
function M.isRunning()
    local pid = readPid()
    if not pid then return false end
    if exists("/proc/" .. pid) then return true end
    os.remove(PID_FILE)
    return false
end

-- (asking the system is slow on a Kindle: once every 20 s is plenty)
local ip_cache = { at = 0 }
function M.ip()
    if os.time() - ip_cache.at < 20 then return ip_cache.ip end
    local ok, info = pcall(function() return Device.retrieveNetworkInfo and Device:retrieveNetworkInfo() end)
    local ip
    if ok and info then
        if type(info) == "table" then ip = info.ip else ip = tostring(info):match("(%d+%.%d+%.%d+%.%d+)") end
    end
    ip_cache.at, ip_cache.ip = os.time(), ip
    return ip
end

function M.url()
    local ip = M.ip()
    if not ip then return nil end
    local port = M.port()
    return "http://" .. ip .. (port == 80 and "" or (":" .. port))
end

local function paths()
    local dir = dataDir()
    return dir .. "/filebrowser.db", dir .. "/config.json", dir .. "/transfer.log"
end

local function run(args)
    local db, cfg = paths()
    return os.execute(string.format("%s -d %s -c %s %s > /dev/null 2>&1", quote(BIN), quote(db), quote(cfg), args))
end

--- FilebrowserPlus's database (your password), taken over once, while that
--- plugin is still installed.
function M.migrate()
    local db = paths()
    if exists(db) then return true end
    local old = PLUGIN_DIR:match("^(.*)/[^/]+$")
    old = old and (old .. "/filebrowserplus.koplugin/filebrowser.db")
    if old and exists(old) then
        local fi = io.open(old, "rb")
        local fo = fi and io.open(db, "wb")
        if fi and fo then
            fo:write(fi:read("*a"))
            fo:close() fi:close()
            return true
        end
        if fi then fi:close() end
    end
    return false
end

--- First run: FilebrowserPlus's database if it's there, else a fresh one
--- with the default login.
local function ensureDatabase()
    if M.migrate() then return true end
    run("config init")
    local ok = run(string.format("users add %s %s --perm.admin", USER, DEFAULT_PASS)) == 0
    if ok then set("stui_default_login", true) end
    return ok
end

local function firewall(open)
    if not Device:isKindle() then return end
    local flag = open and "-A" or "-D"
    local port = M.port()
    os.execute(string.format("iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", flag, port))
    os.execute(string.format("iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", flag, port))
end

local stop_at
local function autoStopCheck()
    if not M.isRunning() or not stop_at then return end
    if os.time() >= stop_at then
        M.stop(true)
        pcall(function() require("ui/widget/notification"):notify(_("Transfer turned itself off")) end)
        return
    end
    UIManager:scheduleIn(math.min(60, math.max(1, stop_at - os.time())), autoStopCheck)
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
    return math.max(0, math.ceil((stop_at - os.time()) / 60))
end

--- Starts the server. Returns true, or false and why.
function M.start()
    if not M.available() then return false, _("The transfer server isn't in this build.") end
    if M.isRunning() then
        if not stop_at then armAutoStop() end
        return true
    end
    if lfs.attributes(BIN, "mode") == "file" then os.execute("chmod +x " .. quote(BIN)) end
    if not ensureDatabase() then return false, _("The transfer server could not be set up.") end
    local folder = M.folder()
    if not exists(folder) then
        os.execute("mkdir -p " .. quote(folder))
        if not exists(folder) then return false, T(_("The folder %1 can't be made."), folder) end
    end
    -- sign-in method: only when it changed (each change is a slow start of the program)
    local want = M.noPassword() and "noauth" or "json"
    if get("stui_auth", nil) ~= want then
        if run("config set --auth.method=" .. want) == 0 then set("stui_auth", want) end
    end
    local db, cfg, log = paths()
    local size = lfs.attributes(log, "size")
    if size and size > 256 * 1024 then os.remove(log) end
    firewall(true)
    local cmd = string.format("nohup %s -a 0.0.0.0 -r %s -p %d -l %s -d %s -c %s > /dev/null 2>&1 & echo $! > %s",
        quote(BIN), quote(folder), M.port(), quote(log), quote(db), quote(cfg), quote(PID_FILE))
    if os.execute(cmd) ~= 0 then
        firewall(false)
        return false, _("The transfer server did not start.")
    end
    armAutoStop()
    logger.info("ShelfTechUI: transfer server on port", M.port(), "for", folder)
    return true
end

--- Stops the server and waits (briefly) until it has let go of its
--- database: a setting changed straight after must not find it locked.
local function killAndWait(pid)
    if not pid then return end
    os.execute("kill " .. pid .. " 2>/dev/null")
    local ffiutil = require("ffi/util")
    for i = 1, 40 do
        if not exists("/proc/" .. pid) then return end
        if i == 30 then os.execute("kill -9 " .. pid .. " 2>/dev/null") end
        ffiutil.usleep(50000)
    end
end

function M.stop(quiet)
    UIManager:unschedule(autoStopCheck)
    stop_at = nil
    killAndWait(readPid())
    os.remove(PID_FILE)
    firewall(false)
    if not quiet then
        pcall(function() require("ui/widget/notification"):notify(_("Transfer is off")) end)
    end
    if M._page then M._page:refresh("ui") end
end

--- On / off without the page.
function M.toggle()
    if M.isRunning() then return M.stop() end
    local ok, why = M.start()
    local InfoMessage = require("ui/widget/infomessage")
    if not ok then
        UIManager:show(InfoMessage:new{ text = why, icon = "notice-warning" })
        return
    end
    local url = M.url()
    UIManager:show(InfoMessage:new{ timeout = 4,
        text = url and T(_("Transfer is on.\n%1"), url) or _("Transfer is on. Connect to Wi-Fi to use it.") })
end

--- A server left running by an earlier KOReader session keeps its timer.
function M.resume()
    if M.available() then pcall(M.migrate) end
    if M.isRunning() and not stop_at then armAutoStop() end
    if get("autostart", false) == true and not M.isRunning() then M.start() end
end

-- ---------------------------------------------------------------- the page

local AUTO_STOPS = { { 15, _("15 min") }, { 30, _("30 min") }, { 60, _("1 hour") }, { 0, _("Never") } }

local function pickFolder(done)
    require("bos_folders").choose(M.folder(), function(path)
        set("dataPath", path)
        done()
    end, _("Folder to share"))
end

--- A new password (12 characters or more, as File Browser asks).
local function askPassword(done)
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    local dlg
    dlg = InputDialog:new{
        title = _("New password"),
        description = T(_("For signing in as %1 from the browser. At least 12 characters."), USER),
        input = "", text_type = "password",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local pw = dlg:getInputText() or ""
                if #pw < 12 then
                    UIManager:show(InfoMessage:new{ text = _("At least 12 characters, please."), timeout = 3 })
                    return
                end
                UIManager:close(dlg)
                done(pw)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

--- Sets the password (the server is stopped for it, then started again).
function M.setPassword(pw)
    local was = M.isRunning()
    if was then M.stop(true) end
    ensureDatabase()
    local ok = run(string.format("users update %s --password=%s", USER, quote(pw))) == 0
    if ok then set("stui_default_login", pw == DEFAULT_PASS) end
    if was then M.start() end
    return ok
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
    if not M.available() then
        UIManager:show(InfoMessage:new{ text = _("The transfer server isn't in this build of ShelfTechUI.") })
        return
    end
    -- opening the page is asking for it: on at once
    -- (the page shows first, "Starting…"; the server starts just after)
    local why
    local starting = not M.isRunning()

    local qr_cache = {}
    local function draw(self, bb, y, w)
        local x = self.pad
        local W = Screen:getWidth()
        local on = M.isRunning()
        local url = on and M.url()
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
            Page.wrap(bb, url, Page.serif(20, true), tx, y + S(48), tw, 3, S(28))
            Look.label(bb, _("Same Wi-Fi as this device"), tx, y + S(140), tw, S(20), 10, { color = Look.GRAY })
            if not M.noPassword() then
                Look.label(bb, _("Sign in"), tx, y + S(172), tw, S(20), 10, { color = Look.GRAY })
                local login = get("stui_default_login", false) and (USER .. " / " .. DEFAULT_PASS) or T(_("%1 / your password"), USER)
                Look.label(bb, login, tx, y + S(194), tw, S(22), 12, { keep_case = true })
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
        local pw_row = row(_("Password"), M.noPassword() and _("Not asked")
            or (get("stui_default_login", false) and _("Default") or _("Your own")), function()
            local function flip() apply(self, function() set("allow_no_password", not M.noPassword()) end) end
            local items = {
                { text = _("Change the password…"), callback = function()
                    askPassword(function(pw)
                        pcall(function() require("ui/widget/notification"):notify(_("Saving the password…")) end)
                        UIManager:forceRePaint()
                        UIManager:nextTick(function()
                            local ok = M.setPassword(pw)
                            UIManager:show(InfoMessage:new{ timeout = 3, text = ok
                                and _("Password changed.") or _("The password could not be changed.") })
                            if not self.closed then self:refresh("ui") end
                        end)
                    end)
                end },
            }
            if M.noPassword() then
                table.insert(items, { text = _("Ask for the password again"), callback = flip })
            else
                table.insert(items, { text = _("Stop asking for a password…"), callback = function()
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Without a password, anyone on this Wi-Fi can read, change and delete the files in the shared folder while Transfer is on.\n\nStop asking for a password?"),
                        ok_text = _("Stop asking"), ok_callback = flip,
                    })
                end })
            end
            table.insert(items, { text = T(_("Back to the default (%1)"), DEFAULT_PASS), callback = function()
                UIManager:nextTick(function()
                    local ok = M.setPassword(DEFAULT_PASS)
                    UIManager:show(InfoMessage:new{ timeout = 3, text = ok
                        and T(_("The login is %1 / %2 again."), USER, DEFAULT_PASS) or _("The password could not be reset.") })
                    if not self.closed then self:refresh("ui") end
                end)
            end })
            require("bos_ui").openList(items, self._pw_rect)
        end)
        self._pw_rect = pw_row
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
                    UIManager:show(InfoMessage:new{ text = _("Transfer runs the File Browser web server (filebrowser.org) on this device while it's on. It takes over from the FilebrowserPlus plugin by Neeraj Patel, with the same settings and password.") })
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
