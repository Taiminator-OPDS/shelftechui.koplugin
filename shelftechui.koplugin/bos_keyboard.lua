--[[
A quicker keyboard (as a Kindle's own): a key types at once.

KOReader's keyboard, on each tap: draws the key pressed and waits for the
screen to show it, draws it released, types, and waits again; on e-ink that's
two full round trips per letter. Here: the letter is typed at once, the key
is shown pressed for a moment without waiting on the screen, and the text
being typed is drawn with the screen's fast mode (cleaned up with one normal
redraw when you pause).

On unless turned off: Settings → Device → Keyboard. KOReader's own "Flash
keyboard" setting still decides whether keys show being pressed at all.

  M.install()   once, at start
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

function M.enabled() return require("bos_settings_store").get("quick_keyboard") ~= false end

local function onScreen(w)
    for _i, e in ipairs(UIManager._window_stack or {}) do
        if e.widget == w then return true end
    end
    return false
end

-- KOReader's key class (local to its keyboard), patched through the first
-- key it makes
local function patchKey(VirtualKey)
    if VirtualKey._stui_quick then return end
    VirtualKey._stui_quick = true
    local orig_tap = VirtualKey.onTapSelect
    VirtualKey.onTapSelect = function(self, skip_flash)
        if not M.enabled() then return orig_tap(self, skip_flash) end
        Device:performHapticFeedback("KEYBOARD_TAP")
        self.keyboard.ignore_first_hold_release = false
        local show = self.flash_keyboard and not skip_flash and not self.skiptap
        -- pressed: drawn, its refresh queued with the letter's (no waiting)
        if show then pcall(self.invert, self, true) end
        if self.callback then self.callback() end
        if show then
            local kb = self.keyboard
            UIManager:scheduleIn(0.12, function()
                -- (only while this keyboard is up: a key that closed it, or
                -- changed its layer, isn't drawn again over what's there)
                if kb and onScreen(kb) and self[1] and self[1].dimen and self[1].dimen.x then
                    pcall(self.invert, self, false)
                end
            end)
        end
        return true
    end
end

function M.install()
    local okK, VirtualKeyboard = pcall(require, "ui/widget/virtualkeyboard")
    if okK and type(VirtualKeyboard) == "table" and not VirtualKeyboard._stui_quick then
        VirtualKeyboard._stui_quick = true
        local orig_add = VirtualKeyboard.addKeys
        VirtualKeyboard.addKeys = function(self, ...)
            local r = orig_add(self, ...)
            pcall(function()
                local key = self.layout and self.layout[1] and self.layout[1][1]
                local cls = key and getmetatable(key)
                if cls and cls.onTapSelect then patchKey(cls) end
            end)
            return r
        end
    end
    -- the text being typed: the fast refresh, then one normal redraw
    local okI, InputText = pcall(require, "ui/widget/inputtext")
    if okI and type(InputText) == "table" and not InputText._stui_quick then
        InputText._stui_quick = true
        local orig_init = InputText.initTextBox
        InputText.initTextBox = function(self, ...)
            local typing = M.enabled() and not self.for_measurement_only and self.keyboard
                and self.isKeyboardVisible and self:isKeyboardVisible()
            if not typing then return orig_init(self, ...) end
            local sd = UIManager.setDirty
            UIManager.setDirty = function(um, w, mode, region, ...)
                if mode == "ui" then
                    mode = "fast"
                elseif type(mode) == "function" then
                    local m = mode
                    mode = function()
                        local t, r, d = m()
                        if t == "ui" then t = "fast" end
                        return t, r, d
                    end
                end
                return sd(um, w, mode, region, ...)
            end
            local ok, err = pcall(orig_init, self, ...)
            UIManager.setDirty = sd
            if not ok then error(err, 0) end
            -- a pause in typing: drawn properly once
            if self._stui_clean then UIManager:unschedule(self._stui_clean) end
            self._stui_clean = function()
                if self.dimen and self.dimen.x and self.parent then
                    UIManager:setDirty(self.parent, "ui", self.dimen)
                end
            end
            UIManager:scheduleIn(0.9, self._stui_clean)
        end
    end
    logger.dbg("ShelfTechUI: quick keyboard installed")
end

return M
