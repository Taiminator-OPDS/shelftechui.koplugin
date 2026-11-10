--[[
Device comforts (Aleph ideas C4, C5).

  Home edge swipes   on Bookshelf's home: slide up or down along the LEFT edge
                     for brightness, the RIGHT edge for warmth (a longer slide,
                     a bigger change), and a diagonal swipe anywhere for a full
                     refresh of the screen. Settings → Home → Edge swipes.
  Interface size     100% to 120%: KOReader's own screen DPI, scaled from the
                     device's, so everything (KOReader, Bookshelf, ShelfTechUI)
                     grows together. Takes effect after a restart.
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Store = require("bos_settings_store")
local Screen = Device.screen

local M = {}

local EDGE = 0.08

local function notify(text)
    pcall(function() require("ui/widget/notification"):notify(text) end)
end

local function stepFor(ges)
    local H = Screen:getHeight()
    local pct = math.floor((ges.distance or 0) / H * 120 + 0.5)
    pct = math.max(5, math.min(60, pct))
    return (ges.direction == "north") and pct or -pct
end

local function brightness(ges)
    if not Device:hasFrontlight() then return false end
    local p = Device:getPowerDevice()
    local lo, hi = p.fl_min or 0, p.fl_max or 100
    local cur = p:isFrontlightOn() and p:frontlightIntensity() or lo
    local new = math.max(lo, math.min(hi, cur + math.floor(stepFor(ges) * (hi - lo) / 100 + 0.5)))
    p:setIntensity(new)
    notify(T(_("Brightness %1%"), math.floor((new - lo) / math.max(1, hi - lo) * 100 + 0.5)))
    return true
end

local function warmth(ges)
    if not Device:hasNaturalLight() then return false end
    local p = Device:getPowerDevice()
    local cur = p:frontlightWarmth() or 0
    local new = math.max(0, math.min(100, cur + stepFor(ges)))
    p:setWarmth(new)
    notify(T(_("Warmth %1%"), new))
    return true
end

local DIAGONAL = { northeast = true, northwest = true, southeast = true, southwest = true }

--- The gesture, if it's one of ours (returns true when handled).
function M.homeGesture(ges)
    if Store.get("home_edge_swipes") == false or type(ges) ~= "table" or ges.ges ~= "swipe" or not ges.pos then
        return false
    end
    if DIAGONAL[ges.direction] then
        UIManager:setDirty(nil, "full")
        return true
    end
    if ges.direction ~= "north" and ges.direction ~= "south" then return false end
    local W = Screen:getWidth()
    if ges.pos.x < W * EDGE then return brightness(ges) end
    if ges.pos.x > W * (1 - EDGE) then return warmth(ges) end
    return false
end

function M.installHome()
    if M._home then return end
    local ok, BW = pcall(require, "lib/bookshelf_widget")
    if not ok or type(BW) ~= "table" or type(BW.handleEvent) ~= "function" then return end
    M._home = true
    local orig = BW.handleEvent
    BW.handleEvent = function(self, event)
        if event.handler == "onGesture" and not Device.screen_saver_lock then
            local okG, done = pcall(M.homeGesture, event.args and event.args[1])
            if okG and done then return true end
            if not okG then logger.warn("ShelfTechUI: home edge swipe:", done) end
        end
        return orig(self, event)
    end
end

-- ---------------------------------------------------------------- interface size

M.SIZES = { 100, 105, 110, 115, 120 }

function M.deviceDPI()
    return Device.screen_dpi or Screen.device and Screen.device.screen_dpi or Screen:getDPI()
end

function M.currentSize()
    local o = G_reader_settings:readSetting("screen_dpi")
    local base = M.deviceDPI()
    if not o or not base or base <= 0 then return 100 end
    return math.floor(o / base * 100 + 0.5)
end

function M.setSize(pct)
    local base = M.deviceDPI()
    local val = (pct ~= 100 and base) and math.floor(base * pct / 100 + 0.5) or nil
    G_reader_settings:saveSetting("screen_dpi", val)
    pcall(function() Device:setScreenDPI(val) end)
    UIManager:askForRestart(T(_("Interface size %1%. KOReader needs to restart for it to take effect."), pct))
end

return M
