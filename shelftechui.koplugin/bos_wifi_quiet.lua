--[[
Wi-Fi without the running commentary: KOReader's progress messages
("Scanning for networks…", "Turning on Wi-Fi…", "Connecting to network …",
"Wi-Fi off." and the like) aren't shown. ShelfTechUI's Wi-Fi chip, tile and
status line already say what Wi-Fi is doing.

Only those short-lived messages go, matched on KOReader's own texts.
Questions ("Do you want to turn on Wi-Fi?"), menus (the list of networks)
and anything else that merely mentions Wi-Fi still show: hiding those would
make what's behind them do nothing.

On unless turned off: Settings → Connect → Wi-Fi messages.

  M.install()   once, at start
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

-- KOReader's Wi-Fi progress texts, as they begin (lowercase); translated
-- KOReaders' own words are matched too (the list below adds them)
local TEXTS = {
    "Scanning for networks…",
    "Turning on Wi-Fi…",
    "Turning off Wi-Fi…",
    "Connecting to network %1…",
    "Connected to network %1",
    "Obtaining IP address…",
    "Wi-Fi off.",
    "Already connected.",
    "Already connected to network %1.",
}

local prefixes
local function build()
    prefixes = {}
    local _ = require("gettext")
    local function add(s)
        s = tostring(s):gsub("%%1.*$", ""):lower():gsub("^%s+", "")
        if #s >= 4 then prefixes[#prefixes + 1] = s end
    end
    for _i, t in ipairs(TEXTS) do
        add(t)
        local ok, tr = pcall(_, t)
        if ok and type(tr) == "string" and tr ~= t then add(tr) end
    end
end

function M.enabled() return require("bos_settings_store").get("wifi_quiet") ~= false end

local function isa(widget, class)
    local mt = getmetatable(widget)
    for _n = 1, 8 do
        if mt == nil then return false end
        if mt == class then return true end
        mt = getmetatable(mt)
    end
    return false
end

local InfoMessage, Notification
--- Is this one of KOReader's Wi-Fi progress messages?
function M.isWifiToast(widget)
    if type(widget) ~= "table" or type(widget.text) ~= "string" then return false end
    InfoMessage = InfoMessage or require("ui/widget/infomessage")
    Notification = Notification or require("ui/widget/notification")
    if not (isa(widget, InfoMessage) or isa(widget, Notification) or widget.toast == true) then return false end
    if not prefixes then build() end
    local s = widget.text:lower():gsub("^%s+", "")
    for _i, p in ipairs(prefixes) do
        if s:sub(1, #p) == p then return true end
    end
    return false
end

function M.install()
    if UIManager._stui_wifi_quiet then return end
    UIManager._stui_wifi_quiet = true
    local orig = UIManager.show
    UIManager.show = function(self, widget, ...)
        if M.enabled() then
            local ok, hide = pcall(M.isWifiToast, widget)
            if ok and hide then
                logger.dbg("ShelfTechUI: Wi-Fi message not shown:", widget.text)
                return
            end
        end
        return orig(self, widget, ...)
    end
end

return M
