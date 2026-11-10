--[[
Highlight handles (Aleph idea B3): when you've selected text and KOReader's
highlight menu is up, a post with a square knob stands at each end of the
selection. Drag either one to move that end: a word at a time in reflowable
books; in a PDF the text under your finger. The menu then acts on the new
selection.

The handles sit under the menu (so its buttons keep working) and only take
touches on the knobs.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Look = require("bos_look")
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local S = Look.S

local M = {}

local Handles = InputContainer:extend{
    name = "stui_highlight_handles",
    is_always_active = true,
    ui = nil,
}

local function screenBoxes(ui, sel)
    local boxes = sel and sel.sboxes or {}
    if #boxes == 0 then return {} end
    if ui.paging then
        local page = ui.highlight.hold_pos and ui.highlight.hold_pos.page
        local out = {}
        for _i, b in ipairs(boxes) do
            local r = ui.view:pageToScreenTransform(page, b)
            if r then table.insert(out, r) end
        end
        return out
    end
    return boxes
end

function Handles:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    local function knobRange(which)
        return function()
            -- while a knob is held, the whole screen is ours (a drag across the
            -- menu must not move the menu)
            if self.dragging then return self.dimen end
            local k = self.knobs and self.knobs[which]
            if not k then return Geom:new{ x = -10, y = -10, w = 1, h = 1 } end
            local g = S(22)
            return Geom:new{ x = k.x - g, y = k.y - g, w = k.w + 2 * g, h = k.h + 2 * g }
        end
    end
    self.ges_events = {}
    for _i, which in ipairs{ "start", "end" } do
        for _j, g in ipairs{ "touch", "pan", "hold_pan", "pan_release", "hold_release", "hold" } do
            self.ges_events["Handle_" .. which .. "_" .. g] = { GestureRange:new{ ges = g, range = knobRange(which) },
                event = "HandleGesture", args = which }
        end
    end
    self:layout()
end

--- Where the two posts stand, from the selection's boxes on screen.
function Handles:layout()
    local boxes = screenBoxes(self.ui, self.ui.highlight and self.ui.highlight.selected_text)
    self.knobs, self.posts = nil, nil
    if #boxes == 0 then return end
    local first, last = boxes[1], boxes[#boxes]
    local k = S(15)
    local t = math.max(3, S(3))
    self.posts = {
        start = { x = first.x - math.floor(t / 2), y = first.y, h = first.h },
        ["end"] = { x = last.x + last.w - math.floor(t / 2), y = last.y, h = last.h },
    }
    self.knobs = {
        start = Geom:new{ x = self.posts.start.x - math.floor((k - t) / 2), y = first.y - k, w = k, h = k },
        ["end"] = Geom:new{ x = self.posts["end"].x - math.floor((k - t) / 2), y = last.y + last.h, w = k, h = k },
    }
    self.last_box = last
    self:clearMenu()
    self.post_w = t
    self.anchor = {
        start = { x = first.x + 1, y = first.y + math.floor(first.h / 2) },
        ["end"] = { x = last.x + last.w - 1, y = last.y + math.floor(last.h / 2) },
    }
end

--- Where the menu is on screen: the first painted frame in it smaller
--- than the screen (its full-screen centring container doesn't count).
function Handles:menuRect()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local function walk(w, depth)
        if type(w) ~= "table" or depth > 8 then return nil end
        local d = w.dimen
        if type(d) == "table" and d.x and d.w and d.w > 0 and (d.w < W or d.h < H) then return d end
        if w.movable then local r = walk(w.movable, depth + 1) if r then return r end end
        for i = 1, #w do
            local r = walk(w[i], depth + 1)
            if r then return r end
        end
    end
    return walk(self.dialog, 0)
end

--- The end knob hangs below the line, unless the menu is there: then above.
function Handles:clearMenu()
    local menu = self:menuRect()
    local k, last = self.knobs and self.knobs["end"], self.last_box
    if not (menu and menu.w and menu.w > 0 and k and last) then return end
    local below = Geom:new{ x = k.x, y = last.y + last.h, w = k.w, h = k.h }
    k.y = below:intersectWith(menu) and (last.y - k.h) or below.y
end

function Handles:region()
    if not self.knobs then return nil end
    local r
    for _i, which in ipairs{ "start", "end" } do
        local k, p = self.knobs[which], self.posts[which]
        local g = Geom:new{ x = k.x - S(4), y = math.min(k.y, p.y) - S(4), w = k.w + S(10),
            h = math.max(k.y + k.h, p.y + p.h) - math.min(k.y, p.y) + S(10) }
        r = r and r:combine(g) or g
    end
    return r
end

function Handles:paintTo(bb, x, y)
    local ok, err = pcall(self.paintKnobs, self, bb)
    if not ok then logger.warn("ShelfTechUI: highlight handles:", err) end
end

function Handles:paintKnobs(bb)
    if not self.knobs then return end
    self:clearMenu()
    for _i, which in ipairs{ "start", "end" } do
        local p, k = self.posts[which], self.knobs[which]
        bb:paintRect(p.x, p.y, self.post_w, p.h, BLACK)
        local held = self.dragging == which
        Look.box(bb, k.x, k.y, k.w, k.h, { fill = held and BLACK or WHITE, border = math.max(2, S(2)) })
    end
end

--- Selects from the fixed end to `pos` (the end being dragged).
function Handles:extendTo(which, pos)
    local ui = self.ui
    local hl = ui.highlight
    local other = which == "start" and self.anchor["end"] or self.anchor.start
    if not other then return end
    local p0 = ui.view:screenToPageTransform({ x = other.x, y = other.y })
    local p1 = ui.view:screenToPageTransform({ x = pos.x, y = pos.y })
    if not (p0 and p1) then return end
    local ok, sel = pcall(ui.document.getTextFromPositions, ui.document, p0, p1)
    if not ok or not sel or not sel.text or sel.text == "" then return end
    if hl.selected_text and hl.selected_text.text == sel.text then return end
    local old = self:region()
    hl.selected_text = sel
    hl.is_word_selection = false
    if ui.paging and hl.hold_pos then ui.view.highlight.temp[hl.hold_pos.page] = sel.sboxes end
    self:layout()
    UIManager:setDirty(ui, "fast")
    local r = self:region()
    if old then r = r and r:combine(old) or old end
    if r then UIManager:setDirty(self, "fast", r) end
end

--- On top of the menu while a knob is held; back under it after.
function Handles:raise(up)
    local stack = UIManager._window_stack
    local mine
    for i, w in ipairs(stack) do if w.widget == self then mine = i break end end
    if not mine then return end
    local entry = table.remove(stack, mine)
    if up then
        table.insert(stack, entry)
    else
        local at = #stack + 1
        for i, w in ipairs(stack) do if w.widget == self.dialog then at = i break end end
        table.insert(stack, at, entry)
    end
end

function Handles:onHandleGesture(which, ges)
    local ok, err = pcall(self.handleGesture, self, which, ges)
    if not ok then
        logger.warn("ShelfTechUI: highlight handles:", err)
        M.close()
    end
    return true
end

function Handles:handleGesture(which, ges)
    local g = ges.ges
    which = self.dragging or which
    if g == "touch" or g == "hold" then
        if not self.dragging then
            self.dragging = which
            self:raise(true)
        end
        UIManager:setDirty(self, "fast", self:region())
        return true
    end
    if g == "pan" or g == "hold_pan" then
        if not self.dragging then
            self.dragging = which
            self:raise(true)
        end
        self:extendTo(which, ges.pos)
        return true
    end
    -- released: the menu again, for the new selection (its quote changes)
    if self.dragging then
        self:extendTo(which, ges.pos)
        self.dragging = nil
        self:raise(false)
        UIManager:setDirty(self, "ui", self:region())
        local ui, dialog = self.ui, self.dialog
        if dialog and ui.highlight.selected_text and ui.highlight.selected_text.text ~= self.start_text then
            UIManager:nextTick(function()
                pcall(function()
                    if ui.highlight.highlight_dialog ~= dialog then return end
                    local hold = ui.highlight.hold_pos
                    UIManager:close(dialog)
                    ui.highlight.hold_pos = hold
                    ui.highlight:onShowHighlightMenu()
                end)
            end)
        end
    end
    return true
end

--- Once the menu has been drawn (and so has a place), move the end knob
--- off it if need be.
function Handles:onShow()
    UIManager:nextTick(function()
        pcall(function()
            if not self.knobs then return end
            local before = self:region()
            local y0 = self.knobs["end"].y
            self:clearMenu()
            if self.knobs["end"].y ~= y0 then
                UIManager:setDirty(self.ui, "ui", before:combine(self:region()))
            end
        end)
    end)
    return true
end

function Handles:onCloseWidget()
    local r = self:region()
    if r then UIManager:setDirty(self.ui, "ui", r) end
end

local live

function M.close()
    if live then
        UIManager:close(live)
        live = nil
    end
end

--- Shows the handles under KOReader's highlight menu (`dialog`).
function M.show(ui, dialog)
    M.close()
    -- only under KOReader's highlight menu (nothing to sit under otherwise)
    if not (dialog and ui and ui.highlight and ui.highlight.selected_text) then return end
    local h = Handles:new{ ui = ui, dialog = dialog, start_text = ui.highlight.selected_text.text }
    if not h.knobs then return end
    live = h
    -- under the menu: the menu keeps its taps; the knobs get the rest
    local stack = UIManager._window_stack
    UIManager:show(h)
    if dialog and stack and #stack >= 2 and stack[#stack].widget == h and stack[#stack - 1].widget == dialog then
        stack[#stack], stack[#stack - 1] = stack[#stack - 1], stack[#stack]
    end
    UIManager:setDirty(h, "ui", h:region())
end

function M.install()
    if M._installed then return end
    M._installed = true
    local ok, err = pcall(function()
        local RH = require("apps/reader/modules/readerhighlight")
        local orig = RH.onShowHighlightMenu
        RH.onShowHighlightMenu = function(self, index, ...)
            local res = orig(self, index, ...)
            if index == nil and require("bos_settings_store").get("highlight_handles") ~= false then
                local dlg = self.highlight_dialog
                pcall(M.show, self.ui, dlg)
                if dlg and live then
                    local close = dlg.onCloseWidget
                    dlg.onCloseWidget = function(d, ...)
                        pcall(M.close)
                        if close then return close(d, ...) end
                    end
                end
            end
            return res
        end
    end)
    if not ok then logger.warn("ShelfTechUI: highlight handles not installed:", err) end
end

return M
