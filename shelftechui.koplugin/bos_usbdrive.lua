--[[
USB drive on a Kindle, without leaving KOReader by hand.

KOReader lives on the partition a computer takes over in USB drive mode, so it
can't stay open meanwhile (KOReader's own launcher holds the Kindle's USB
drive mode back while it runs). So: what's open is saved, KOReader closes, the
Kindle's own USB drive mode takes over, and when the computer lets go
(ejected, or unplugged) KOReader starts again by itself (usbdrive.sh, from a
copy in /var/tmp), back where you were.

  * Plugged in: asked once each time ("USB drive" / "Just charge"), only
    when it's a computer. What it's plugged into is told by the USB port
    (a computer talks to it: the port is "configured", at a speed; a charger
    only gives power) and by the charger's own report (SDP/CDP: a computer,
    DCP: a wall charger); when neither says, it asks as before. What was
    seen is written to koreader/stui_usbprobe.log. Settings → Device → USB
    drive turns the question off.
  * Any time: the USB drive control (Quick Settings tile, home chip), its
    row in Settings, and a gesture action.

Kindle only (Kobo has KOReader's own USB storage).

  M.available()
  M.start(ask)     ask: show the question first
  M.onPlugged()    the device started charging
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Store = require("bos_settings_store")

local M = {}

local PLUGIN_DIR = (debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*$", "%1"))

function M.available()
    return Device:isKindle() or os.getenv("STUI_USBDRIVE_TEST") ~= nil
end

local function plugged()
    local ok, on = pcall(function() return Device:getPowerDevice():isCharging() end)
    return ok and on
end

--- KOReader's folder (koreader.sh runs it from there).
local function koDir()
    return os.getenv("KOREADER_DIR") or require("libs/libkoreader-lfs").currentdir()
end

--- The flags KOReader was started with that it should start with again.
local function flags()
    if os.getenv("STOP_FRAMEWORK") == "yes" then return "--framework_stop" end
    return ""
end

local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

--- The helper, copied out of the shared partition and started on its own.
function M.launchHelper()
    local src = PLUGIN_DIR .. "/usbdrive.sh"
    local dst = os.getenv("STUI_USBDRIVE_TMP") or "/var/tmp/stui_usbdrive.sh"
    local fi = io.open(src, "rb")
    if not fi then return false, "no helper" end
    local body = fi:read("*a")
    fi:close()
    local fo = io.open(dst, "wb")
    if not fo then return false, "can't write " .. dst end
    fo:write(body)
    fo:close()
    os.execute("chmod 755 " .. shq(dst))
    -- (twice in the background: it outlives KOReader and its launcher)
    local cmd = string.format("sh -c %s </dev/null >/dev/null 2>&1",
        shq(string.format("sh %s %s %s </dev/null >/dev/null 2>&1 &", shq(dst), shq(koDir()), flags())))
    local r = os.execute(cmd)
    return r == 0 or r == true
end

--- Save, start the helper, close KOReader.
function M.go()
    local ok, why = M.launchHelper()
    if not ok then
        logger.warn("ShelfTechUI: USB drive helper didn't start:", why)
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("USB drive mode couldn't start. Close KOReader and plug the cable in again."), timeout = 5 })
        return
    end
    logger.info("ShelfTechUI: closing KOReader for USB drive mode")
    if M._test_quit then return M._test_quit() end
    UIManager:flushSettings()
    UIManager:broadcastEvent(require("ui/event"):new("Close"))
    UIManager:quit(0)
end

function M.start(ask)
    if not M.available() then return end
    if not plugged() then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Plug the Kindle into the computer first, then choose USB drive."), timeout = 4 })
        return
    end
    if ask == false then return M.go() end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Use as a USB drive?\n\nKOReader closes while the computer has the Kindle, and opens again by itself when you eject it, where you were."),
        ok_text = _("USB drive"),
        ok_callback = function() M.go() end,
    })
end

-- ---------------------------------------------------------------- computer or charger?

-- What the kernel says about the USB port and the charger, as "path=value"
-- lines (one shell, a few small files).
local PROBE = [[
for f in /sys/class/udc/*/state /sys/class/udc/*/current_speed \
         /sys/class/power_supply/*/type /sys/class/power_supply/*/usb_type /sys/class/power_supply/*/real_type \
         /sys/class/power_supply/*/online /sys/class/power_supply/*/charge_type /sys/class/power_supply/*/charger_type \
         /sys/class/power_supply/*/chg_type /sys/devices/platform/charger/charger_type /sys/devices/platform/charger/type; do
  [ -r "$f" ] && echo "$f=$(head -c 120 "$f" 2>/dev/null | tr '\n' ' ')"
done 2>/dev/null
]]

function M.probe()
    if os.getenv("STUI_USB_PROBE") then return os.getenv("STUI_USB_PROBE") end
    local okP, out = pcall(function()
        local f = io.popen(PROBE)
        if not f then return "" end
        local s2 = f:read("*a") or ""
        f:close()
        return s2
    end)
    return okP and out or ""
end

--- "computer" | "charger" | nil (can't tell), from the probe's lines.
function M.classify(text)
    local computer, charger = false, false
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local path, value = line:match("^(.-)=(.*)$")
        if path then
            value = value:gsub("%s+$", "")
            local low = value:lower()
            -- the selected one of a list ("Unknown [SDP] DCP CDP") or the value
            local sel = (value:match("%[([^%]]+)%]") or value):upper()
            if path:match("/udc/.*/state$") then
                if low == "configured" or low == "addressed" then computer = true end
            elseif path:match("/udc/.*/current_speed$") then
                if low ~= "" and low ~= "unknown" then computer = true end
            elseif path:match("usb_type$") or path:match("/type$") or path:match("real_type$")
                    or path:match("charger_type$") or path:match("chg_type$") then
                if sel:match("SDP") or sel:match("CDP") or sel == "USB" and path:match("usb_type$") then computer = true
                elseif sel:match("DCP") or sel:match("MAINS") or sel:match("^AC") or sel:match("WALL") or sel:match("ADAPTER") then charger = true end
            end
        end
    end
    if computer then return "computer" end
    if charger then return "charger" end
    return nil
end

--- What was seen, kept beside KOReader (to be read over USB), the latest last.
local function note(what, text)
    pcall(function()
        local path = require("datastorage"):getDataDir() .. "/stui_usbprobe.log"
        local lfs = require("libs/libkoreader-lfs")
        local size = lfs.attributes(path, "size") or 0
        local f = io.open(path, size > 30000 and "w" or "a")
        if not f then return end
        f:write(os.date("%Y-%m-%d %H:%M:%S"), "  ", what, "\n", text, "\n")
        f:close()
    end)
    logger.info("ShelfTechUI: USB plugged in:", what)
end

--- Plugged in: the question (unless turned off), once per plugging in, if
--- it's (or may be) a computer.
function M.onPlugged()
    if not M.available() or Store.get("usb_ask") == false then return end
    -- (the event can come twice: asked once)
    if M._asking then return end
    M._asking = true
    -- (a computer takes a moment to talk to the port: looked at twice)
    UIManager:scheduleIn(1.5, function()
        if not plugged() then M._asking = false return end
        local text = M.probe()
        local kind = M.classify(text)
        if kind == "computer" then
            note("computer (1.5 s)", text)
            M._asking = false
            return M.ask()
        end
        UIManager:scheduleIn(2.5, function()
            M._asking = false
            if not plugged() then return end
            local text2 = M.probe()
            local kind2 = M.classify(text2) or kind
            note((kind2 or "can't tell") .. " (4 s)", text2)
            if kind2 == "charger" then return end
            M.ask()
        end)
    end)
end

--- The question: USB drive, or just charge.
function M.ask()
    do
        if not plugged() then return end
        local ButtonDialog = require("ui/widget/buttondialog")
        local dlg
        dlg = ButtonDialog:new{
            title = _("Plugged in"),
            title_align = "center",
            buttons = {
                { { text = _("USB drive"), callback = function() UIManager:close(dlg) M.go() end } },
                { { text = _("Just charge"), callback = function() UIManager:close(dlg) end } },
                { { text = _("Don't ask when plugged in"), callback = function()
                    UIManager:close(dlg)
                    Store.set("usb_ask", false)
                end } },
            },
        }
        M._dialog = dlg
        UIManager:show(dlg)
    end
end

--- Unplugged: the question goes.
function M.onUnplugged()
    if M._dialog then pcall(function() UIManager:close(M._dialog) end) M._dialog = nil end
end

return M
