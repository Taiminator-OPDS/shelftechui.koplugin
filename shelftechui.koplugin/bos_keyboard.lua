--[[
A quicker keyboard (as a Kindle's own): a key types at once.

KOReader's keyboard, on each tap: draws the key pressed and waits for the
screen to show it, draws it released, types, and waits again; on e-ink that's
two full round trips per letter. Here: the letter is typed at once, the key
is shown pressed for a moment without waiting on the screen, and the text
being typed is drawn with the screen's fast mode (cleaned up with one normal
redraw when you pause).

And it looks like a Kindle's: white rounded keys for letters, numbers and the
space bar, darker grey ones for shift, backspace, return and the like, on a
light grey panel; a key pressed turns darker for a moment. With KOReader's
"Key border" off (Keyboard → Keyboard appearance), borderless: one white
board, the keys touching, the ones that don't type in a light grey. With its
"Compact" on: lower rows than KOReader's compact, labels in proportion and
no long-press hints in the keys' corners, so it's smaller without crowding. Done to KOReader's
keyboard as it's built (KOReader's own files aren't changed).

Both on unless turned off: Settings → Device → Keyboard. KOReader's own
"Flash keyboard" setting still decides whether keys show being pressed.

  M.install()   once, at start
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

function M.enabled() return require("bos_settings_store").get("quick_keyboard") ~= false end
function M.kindleLook() return require("bos_settings_store").get("keyboard_look") ~= "koreader" end

-- the Kindle keyboard's greys
local PANEL = Blitbuffer.Color8(0xD8)     -- behind the keys
local KEY = Blitbuffer.COLOR_WHITE        -- a letter, a number, the space bar
local FUNC = Blitbuffer.Color8(0xB0)      -- shift, backspace, return, SYM…
local ACTIVE = Blitbuffer.Color8(0x80)    -- shift or caps on
local PRESSED = Blitbuffer.Color8(0x70)   -- held down
-- compact (KOReader's "Compact" on): rows this high (KOReader's compact is
-- 48, its regular 64), labels at most this size (KOReader's default 22)
local COMPACT_ROW = 42
local COMPACT_LABEL = 18

-- borderless (KOReader's "Key border" off): one white board, the keys
-- touching; the ones that do something rather than type a light grey
local FLAT_FUNC = Blitbuffer.Color8(0xE0)
local FLAT_ACTIVE = Blitbuffer.Color8(0xB0)
local FLAT_PRESSED = Blitbuffer.Color8(0xC0)

--- KOReader's own "Key border" setting (Keyboard → Keyboard appearance).
function M.bordered() return G_reader_settings:nilOrTrue("keyboard_key_border") end

-- keys that do something rather than type (by their label)
local FUNC_LABELS = { ["\u{2190}"] = true, ["\u{2192}"] = true, ["\u{2191}"] = true, ["\u{2193}"] = true,
    ["\u{2BA0}"] = true, ["\u{1F310}"] = true, ["\u{2325}"] = true, ["\u{21E7}"] = true, ["\u{232B}"] = true }

local function firstCodepoint(s)
    local b = s:byte(1)
    if not b then return nil end
    if b < 0x80 then return b end
    if b >= 0xF0 then return ((b % 8) * 262144) + ((s:byte(2) % 64) * 4096) + ((s:byte(3) % 64) * 64) + (s:byte(4) % 64) end
    if b >= 0xE0 then return ((b % 16) * 4096) + ((s:byte(2) % 64) * 64) + (s:byte(3) % 64) end
    return ((b % 32) * 64) + (s:byte(2) % 64)
end

local function isFunctionKey(k)
    if k.icon then return true end
    local label = k.label
    if type(label) ~= "string" or label == "" then return true end
    if FUNC_LABELS[label] then return true end
    if k.alt_label == "SYM" then return true end
    local cp = firstCodepoint(label)
    -- the icon glyphs (shift, backspace…) are in the private-use area
    if cp and ((cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0xF0000) then return true end
    -- a word on a key ("ABC", "123") rather than a character
    local n = select(2, label:gsub("[^\128-\191]", ""))
    return n > 1
end

--- Compact: the key's long-press hint (the small character in its corner)
--- goes, so a low key isn't crowded; holding the key still offers it.
local function plainLabel(k)
    local center = k[1] and k[1][1]
    local og = center and center[1]
    -- (KOReader puts the hint and the label in an OverlapGroup: the label is
    -- its first child's content)
    if k.alt_label and type(og) == "table" and og[1] and og[1][1] then
        center[1] = og[1][1]
    end
end

--- One key in the Kindle's look (after KOReader has built it).
local function dressKey(k, bordered)
    local frame = k[1]
    if type(frame) ~= "table" then return end
    local active = frame.background == Blitbuffer.COLOR_LIGHT_GRAY -- (KOReader's mark for shift/caps on)
    frame.bordersize = 0
    if bordered then
        frame.radius = Device.screen:scaleBySize(10)
        frame.background = active and ACTIVE or (isFunctionKey(k) and FUNC or KEY)
        k._stui_pressed = PRESSED
    else
        frame.radius = 0
        frame.background = active and FLAT_ACTIVE or (isFunctionKey(k) and FLAT_FUNC or KEY)
        k._stui_pressed = FLAT_PRESSED
    end
    k._stui_bg = frame.background
end

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
    -- pressed, in the Kindle's look: the key turns darker (KOReader draws a
    -- black outline inside it)
    local orig_invert = VirtualKey.invert
    VirtualKey.invert = function(self, invert, hold)
        if not (self._stui_bg and self[1]) then return orig_invert(self, invert, hold) end
        self[1].background = invert and (self._stui_pressed or PRESSED) or self._stui_bg
        local f = self[1]
        if not (f.dimen and f.dimen.x) then return end
        UIManager:widgetRepaint(f, f.dimen.x, f.dimen.y)
        if invert then
            -- pressed: on screen now, in the screen's quickest mode (it shows
            -- the grey as dark), not queued behind the letter's typing
            UIManager:setDirty(nil, "a2", f.dimen)
            if M.enabled() then UIManager:forceRePaint() end
        else
            -- released: drawn properly (the quick mode can't show a grey key)
            UIManager:setDirty(nil, "ui", f.dimen)
        end
    end
    -- Pressed at once: when the finger lands (a tap only comes once it's
    -- lifted, and later still while double-taps are on), the key's pixels
    -- turned over and shown in the screen's quickest mode, nothing redrawn.
    VirtualKey.onTouchSelect = function(self)
        if not M.enabled() or self._stui_down or not (self.flash_keyboard and not self.skiptap) then return false end
        local f = self[1]
        local d = f and f.dimen
        if not (d and d.x and d.w and d.w > 0) then return false end
        local ok = pcall(function()
            local Screen = Device.screen
            Screen.bb:invertRect(d.x, d.y, d.w, d.h)
            UIManager:setDirty(nil, "fast", d)
            UIManager:forceRePaint()
        end)
        if ok then
            self._stui_down = true
            -- (a touch that turns into no tap at all: a slide, a hold)
            local key = self
            UIManager:scheduleIn(1.5, function() key:stuiRelease() end)
        end
        return false
    end
    --- Back to the key as it is: drawn again (not turned over again: it may
    --- have been redrawn meanwhile), quickly; the grey keys exactly once
    --- typing pauses.
    VirtualKey.stuiRelease = function(self)
        if not self._stui_down then return end
        self._stui_down = nil
        local kb = self.keyboard
        local f = self[1]
        if not (kb and onScreen(kb) and f and f.dimen and f.dimen.x) then return end
        UIManager:widgetRepaint(f, f.dimen.x, f.dimen.y)
        UIManager:setDirty(nil, "fast", f.dimen)
        if kb._stui_clean then UIManager:unschedule(kb._stui_clean) end
        kb._stui_clean = function()
            if onScreen(kb) and kb.dimen then UIManager:setDirty(kb, "ui", kb.dimen) end
        end
        UIManager:scheduleIn(0.9, kb._stui_clean)
    end
    local orig_hold = VirtualKey.onHoldSelect
    VirtualKey.onHoldSelect = function(self, ...)
        if self._stui_down then self:stuiRelease() end
        return orig_hold(self, ...)
    end
    local orig_tap = VirtualKey.onTapSelect
    VirtualKey.onTapSelect = function(self, skip_flash)
        if not M.enabled() then return orig_tap(self, skip_flash) end
        Device:performHapticFeedback("KEYBOARD_TAP")
        self.keyboard.ignore_first_hold_release = false
        -- shown pressed since the finger landed: the letter, then the key back
        if self._stui_down then
            if self.callback then self.callback() end
            self:stuiRelease()
            return true
        end
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
        local Size = require("ui/size")
        VirtualKeyboard.addKeys = function(self, ...)
            local kindle = M.kindleLook()
            local bordered = M.bordered()
            local compact = kindle and G_reader_settings:isTrue("keyboard_key_compact")
            -- (with borders: a little more room between keys, so each stands
            -- on its own; without: none, one board)
            if kindle and bordered then self.key_padding = compact and Size.padding.small or Size.padding.default
            elseif kindle then self.key_padding = 0
            else self.key_padding = Size.padding.small end
            -- compact (KOReader's "Compact" on): lower rows, and the room in
            -- them given to the keys (no margin round the board)
            if compact then
                self.height = Device.screen:scaleBySize(COMPACT_ROW * #(self.KEYS or {}))
                self.padding = 0
            elseif kindle then
                self.padding = nil -- (KOReader's own)
            end
            -- (the Kindle's keys are in a plain sans-serif: KOReader's UI
            -- font, not its fixed-width keyboard font)
            local Font = require("ui/font")
            local orig_face = Font.getFace
            if kindle then
                local label_size = G_reader_settings:readSetting("keyboard_key_font_size", 22)
                Font.getFace = function(f, font, size, ...)
                    if font == "infont" then
                        font = "cfont"
                        -- (compact: a label in proportion to the lower key)
                        if compact and size == label_size then size = math.min(size, COMPACT_LABEL) end
                    end
                    return orig_face(f, font, size, ...)
                end
            end
            local okA, r = pcall(orig_add, self, ...)
            Font.getFace = orig_face
            if not okA then error(r, 0) end
            pcall(function()
                local key = self.layout and self.layout[1] and self.layout[1][1]
                local cls = key and getmetatable(key)
                if cls and cls.onTapSelect then patchKey(cls) end
            end)
            -- every key: told when a finger lands on it
            if M.enabled() then
                pcall(function()
                    local GestureRange = require("ui/gesturerange")
                    for _r, row in ipairs(self.layout or {}) do
                        for _c, k in ipairs(row) do
                            if type(k) == "table" and k.ges_events and not k.ges_events.TouchSelect then
                                k.ges_events.TouchSelect = { GestureRange:new{ ges = "touch", range = function() return k.dimen end } }
                            end
                        end
                    end
                end)
            end
            if kindle then
                local ok, err = pcall(function()
                    for _r, row in ipairs(self.layout or {}) do
                        for _c, k in ipairs(row) do
                            dressKey(k, bordered)
                            if compact then
                                plainLabel(k)
                                if bordered then k[1].radius = Device.screen:scaleBySize(7) end
                            end
                        end
                    end
                    local frame = self[1] and self[1][1]
                    if frame then
                        if bordered then
                            frame.background = PANEL
                            frame.bordersize = 0
                        else
                            -- (one white board, a thin grey line along its top)
                            frame.background = KEY
                            frame.bordersize = Size.border.default
                            frame.color = Blitbuffer.COLOR_DARK_GRAY
                        end
                    end
                end)
                if not ok then logger.warn("ShelfTechUI: keyboard look:", err) end
            end
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
