--[[
USB drive on a Kindle, without leaving KOReader by hand.

KOReader lives on the partition a computer takes over in USB drive mode, so it
can't stay open meanwhile (KOReader's own launcher holds the Kindle's USB
drive mode back while it runs). So: what's open is saved, KOReader closes, the
Kindle's own USB drive mode takes over, and when the computer lets go
(ejected, or unplugged) KOReader starts again by itself (usbdrive.sh, from a
copy in /var/tmp), back where you were.

  * Plugged in: asked once each time ("USB drive" / "Just charge"); a Kindle
    can't tell a computer from a charger. Settings → Device → USB drive turns
    the question off.
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

--- Plugged in: the question (unless turned off), once per plugging in.
function M.onPlugged()
    if not M.available() or Store.get("usb_ask") == false then return end
    -- (the event can come twice: asked once)
    if M._asking then return end
    M._asking = true
    UIManager:scheduleIn(1.5, function()
        M._asking = false
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
    end)
end

--- Unplugged: the question goes.
function M.onUnplugged()
    if M._dialog then pcall(function() UIManager:close(M._dialog) end) M._dialog = nil end
end

return M
