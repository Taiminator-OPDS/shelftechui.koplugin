--[[
The selection menu, as a phone's: a small bar that hovers just under what
you've selected (or just over it, when there's no room under), with
Highlight · Note · Copy · Look up · ⋯. The ⋯ key turns the bar into the
rest of KOReader's actions (Wikipedia, Translate, Search, Share, Select,
and what plugins add: Pin page, Hardcover…), in a short list at the same
place. It keeps clear of the handles at the ends of the selection, so both
are always within reach.

It's KOReader's own highlight menu redrawn: the same buttons (from
ReaderHighlight's list, plugins' included), doing the same things. A tap
outside it closes it and the selection, as before.

Off: Settings → Reading → Compact selection menu (KOReader's menu again).

  M.install()   once, with the first book
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Look = require("bos_look")
local Screen = Device.screen
local S = Look.S

local M = {}

function M.enabled() return require("bos_settings_store").get("highlight_popup") ~= false end

-- the bar's own keys (by KOReader's ids), with shorter names; the rest go
-- under ⋯
local PRIMARY = {
    { id = "02_highlight", text = _("Highlight") },
    { id = "04_add_note", text = _("Note") },
    { id = "03_copy", text = _("Copy") },
    { id = "06_dictionary", text = _("Look up") },
}

local Popup = InputContainer:extend{
    name = "stui_selection_menu",
    hl = nil,          -- ReaderHighlight
    buttons = nil,     -- { { text, callback, hold_callback, enabled }, ... }
    more = nil,        -- the rest
}

function Popup:init()
    self.page = "bar"
    self.key_h = S(44)
    self.size = 11
    local all = function() return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } end
    self.ges_events = {
        PopTap = { GestureRange:new{ ges = "tap", range = all } },
        PopHold = { GestureRange:new{ ges = "hold", range = all } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    self:layout()
end

--- The selection's extent on the screen: top, bottom, and the x of its
--- first and last ends.
function Popup:selectionBox()
    local hl = self.hl
    local sel = hl.selected_text
    local boxes = sel and (sel.sboxes or sel.pboxes) or {}
    local out = {}
    for _i, b in ipairs(boxes) do
        local r = b
        if hl.ui.paging then
            local page = (sel.pos0 and sel.pos0.page) or (hl.hold_pos and hl.hold_pos.page)
            r = page and hl.view:pageToScreenTransform(page, b)
        end
        if r then out[#out + 1] = r end
    end
    if #out == 0 then return nil end
    local y0, y1 = math.huge, -math.huge
    for _i, r in ipairs(out) do
        y0 = math.min(y0, r.y)
        y1 = math.max(y1, r.y + r.h)
    end
    return { y0 = y0, y1 = y1, x_first = out[1].x, x_last = out[#out].x + out[#out].w }
end

function Popup:items()
    if self.page == "bar" then
        local list = {}
        for _i, b in ipairs(self.buttons) do list[#list + 1] = b end
        if #self.more > 0 then list[#list + 1] = { text = "\u{22EF}", more = true, enabled = true, glyph = true } end
        return list
    end
    return self.more
end

--- Where it goes: under the selection (clear of the end handle), else over
--- it, else at the foot of the screen; across, centred on the selection's
--- end (its start, when over it).
function Popup:layout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad = S(14)
    local items = self:items()
    local w, h
    if self.page == "bar" then
        w = 0
        for _i, it in ipairs(items) do
            it.w = (it.glyph and S(44)) or (Look.textWidth(Look.case(it.text), self.size) + 2 * pad)
            w = w + it.w
        end
        w = math.min(w, W - 2 * S(8))
        h = self.key_h
    else
        -- the rest: two columns of keys
        local col_w = 0
        for _i, it in ipairs(items) do col_w = math.max(col_w, Look.textWidth(Look.case(it.text), self.size) + 2 * pad) end
        local cols = (#items > 4 and 2 * col_w <= W - 2 * S(8)) and 2 or 1
        w = math.min(W - 2 * S(8), cols * col_w)
        self.cols = cols
        h = math.ceil(#items / cols) * S(42)
    end
    local box = self:selectionBox()
    local knob = S(15) + S(22) -- (an end handle, and the reach around it)
    local x, y
    if box then
        if box.y1 + knob + h + S(8) <= H then
            y = box.y1 + knob
            x = box.x_last - math.floor(w / 2)
        elseif box.y0 - knob - h >= S(8) then
            y = box.y0 - knob - h
            x = box.x_first - math.floor(w / 2)
        end
    end
    if not y then
        y = H - h - S(24)
        x = math.floor((W - w) / 2)
    end
    x = math.max(S(8), math.min(W - w - S(8) - Look.SHADOW_SMALL, x))
    self.dimen = Geom:new{ x = x, y = y, w = w + Look.SHADOW_SMALL, h = h + Look.SHADOW_SMALL }
    self.box = Geom:new{ x = x, y = y, w = w, h = h }
end

function Popup:getSize() return self.dimen end

function Popup:paintTo(bb, _x, _y)
    local b = self.box
    self.hits = {}
    Look.box(bb, b.x, b.y, b.w, b.h, { shadow = Look.SHADOW_SMALL })
    local items = self:items()
    if self.page == "bar" then
        local cx = b.x
        for i, it in ipairs(items) do
            local iw = (i == #items) and (b.x + b.w - cx) or it.w
            local on = it.enabled ~= false
            Look.label(bb, it.text, cx, b.y, iw, b.h, it.glyph and 15 or self.size,
                { align = "center", color = on and Look.INK or Look.GRAY, keep_case = it.glyph })
            if i < #items then bb:paintRect(cx + iw - 1, b.y + S(10), math.max(1, S(1)), b.h - S(20), Look.MID) end
            self.hits[#self.hits + 1] = { rect = Geom:new{ x = cx, y = b.y, w = iw, h = b.h }, it = it }
            cx = cx + iw
        end
    else
        local rh = S(42)
        local cw = math.floor(b.w / self.cols)
        for i, it in ipairs(items) do
            local col = (i - 1) % self.cols
            local row = math.floor((i - 1) / self.cols)
            local rx, ry = b.x + col * cw, b.y + row * rh
            local on = it.enabled ~= false
            Look.label(bb, it.text, rx + S(14), ry, cw - S(20), rh, self.size, { color = on and Look.INK or Look.GRAY })
            if row > 0 and col == 0 then bb:paintRect(b.x + S(8), ry, b.w - S(16), math.max(1, S(1)), Look.LIGHT) end
            self.hits[#self.hits + 1] = { rect = Geom:new{ x = rx, y = ry, w = cw, h = rh }, it = it }
        end
    end
end

local function inside(p, r) return p and r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end

function Popup:run(it, hold)
    if it.more then
        -- the rest, in its place
        local old = self.dimen
        self.page = "more"
        self:layout()
        UIManager:setDirty(self.hl.dialog or "all", "ui", old)
        UIManager:setDirty(self, "ui", self.dimen)
        return
    end
    if it.enabled == false then return end
    local fn = hold and it.hold_callback or it.callback
    if not fn then return end
    local ok, err = pcall(fn)
    if not ok then logger.warn("ShelfTechUI: selection menu:", err) end
end

function Popup:onPopTap(_, ges)
    for _i, h in ipairs(self.hits or {}) do
        if inside(ges.pos, h.rect) then
            -- (pressed, for a moment: then what it does)
            pcall(function()
                Screen.bb:invertRect(h.rect.x, h.rect.y, h.rect.w, h.rect.h)
                UIManager:setDirty(nil, "fast", h.rect)
                UIManager:forceRePaint()
            end)
            local it = h.it
            UIManager:nextTick(function() self:run(it) end)
            return true
        end
    end
    -- on a handle: the handle's (a touch there starts a drag)
    local okK, on_knob = pcall(function() return require("bos_handles").knobAt(ges.pos) end)
    if okK and on_knob then return false end
    -- outside: the menu goes, and the selection with it (as KOReader's)
    self:onClose()
    return true
end

function Popup:onPopHold(_, ges)
    for _i, h in ipairs(self.hits or {}) do
        if inside(ges.pos, h.rect) then self:run(h.it, true) return true end
    end
    return false
end

function Popup:onClose()
    local hl = self.hl
    UIManager:close(self)
    if hl.highlight_dialog == self then hl.highlight_dialog = nil end
    if hl.hold_pos then hl:clear() end
    return true
end

function Popup:onShow()
    UIManager:setDirty(self, "ui", self.dimen)
    return true
end

function Popup:onCloseWidget()
    UIManager:setDirty(self.hl.dialog or "all", "ui", self.dimen)
end

--- KOReader's buttons for this selection, as { text, callback, … }.
local function buttonsFor(hl, index)
    local ffiUtil = require("ffi/util")
    local by_id, order = {}, {}
    for id, fn in ffiUtil.orderedPairs(hl._highlight_buttons or {}) do
        local ok, b = pcall(fn, hl, index)
        if ok and type(b) == "table" and (not b.show_in_highlight_dialog_func or b.show_in_highlight_dialog_func()) then
            local text = b.text_func and b.text_func() or b.text
            if type(text) == "string" and text ~= "" then
                local enabled = b.enabled
                if b.enabled_func then
                    local okE, e = pcall(b.enabled_func)
                    enabled = okE and e
                end
                by_id[id] = { text = text, callback = b.callback, hold_callback = b.hold_callback, enabled = enabled ~= false }
                order[#order + 1] = id
            end
        end
    end
    local bar, used = {}, {}
    for _i, p in ipairs(PRIMARY) do
        local b = by_id[p.id]
        if b then
            b.text = p.text
            bar[#bar + 1] = b
            used[p.id] = true
        end
    end
    local more = {}
    for _i, id in ipairs(order) do
        if not used[id] then more[#more + 1] = by_id[id] end
    end
    return bar, more
end

function M.show(hl, index)
    local bar, more = buttonsFor(hl, index)
    if #bar == 0 then return false end
    local p = Popup:new{ hl = hl, buttons = bar, more = more }
    hl.highlight_dialog = p
    UIManager:show(p, "[ui]")
    return true
end

function M.install()
    if M._installed then return end
    M._installed = true
    local ok, err = pcall(function()
        local RH = require("apps/reader/modules/readerhighlight")
        local orig = RH.onShowHighlightMenu
        RH.onShowHighlightMenu = function(self, index, ...)
            if not self.selected_text or not M.enabled() then return orig(self, index, ...) end
            local okS, shown = pcall(M.show, self, index)
            if okS and shown then return end
            if not okS then logger.warn("ShelfTechUI: selection menu, KOReader's instead:", shown) end
            return orig(self, index, ...)
        end
    end)
    if not ok then logger.warn("ShelfTechUI: selection menu not installed:", err) end
end

return M
