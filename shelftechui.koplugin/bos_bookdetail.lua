--[[
A book's details: Bookshelf's own book window (hold a book), with one tab of
ours added to it.

  M.show(fp)                  open Bookshelf's window for a book of yours
                              (from the store, a series page, the library
                              list…); KOReader's book information if
                              Bookshelf's home isn't there to host it
  M.setSummary(fp, k, v)      a book's status or rating, saved where
                              KOReader and Bookshelf read them
  M.recsTab(bw, book, modal)  the "Recommendations" tab: books from the
                              internet for this one (its series and author
                              first, then the rest of your recommendations),
                              big covers, "In library" on the ones you have;
                              a tap opens the store on it (or your own copy)
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Look = require("bos_look")
local UI = require("bos_ui")
local S = Look.S
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = {}

local function repo()
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    return ok and Repo or nil
end

local function readerUI(fp)
    local R = package.loaded["apps/reader/readerui"]
    local ui = R and R.instance
    if ui and ui.document and ui.document.file == fp then return ui end
end

function M.show(fp, opts)
    local ok, done = pcall(function()
        local bw = require("bos_shelf").shelfWidget()
        if not (bw and bw._showBookDetail) or readerUI(fp) then return false end
        local Repo = repo()
        local book = Repo and Repo.buildBook and Repo.buildBook(fp) or { filepath = fp }
        bw:_showBookDetail(book, opts)
        return true
    end)
    if ok and done then return true end
    if not ok then logger.warn("ShelfTechUI: Bookshelf's book window:", done) end
    -- in a book, or without Bookshelf's home: KOReader's own
    local okI = pcall(function() require("apps/filemanager/filemanagerbookinfo"):show(fp) end)
    return okI
end

function M.setSummary(fp, field, value)
    local ui = readerUI(fp)
    local ok, err = pcall(function()
        local ds = ui and ui.doc_settings or require("docsettings"):open(fp)
        local summary = ds:readSetting("summary") or {}
        summary[field] = value
        summary.modified = os.date("%Y-%m-%d", os.time())
        ds:saveSetting("summary", summary)
        if not ui then ds:flush() end
        pcall(function() require("ui/widget/booklist").setBookInfoCacheProperty(fp, field, value) end)
    end)
    if not ok then logger.warn("ShelfTechUI: book status not saved:", err) end
    local Repo = repo()
    if Repo then
        pcall(Repo.invalidateProgressCache, fp)
        pcall(Repo.invalidateReadStateCache)
    end
    pcall(function() require("bos_recs").invalidate() end)
end

-- ---------------------------------------------------------------- the tab

local function tface(size, bold, italic)
    return Look.text(size, bold, italic) or (bold and UI.boldFace(size)) or (italic and UI.italicFace(size)) or UI.face(size)
end

local function inside(p, r) return p and r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end

local RecsTab = InputContainer:extend{
    width = nil, height = nil,
    book = nil,        -- Bookshelf's record of the book
    modal = nil,       -- function() → the window this tab is in
}

function RecsTab:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.page = 1
    self.hits = {}
    local range = function() return self.dimen end
    self.ges_events = { RTap = { GestureRange:new{ ges = "tap", range = range } } }
    self:load()
end

function RecsTab:load()
    local b = self.book or {}
    local ok, list = pcall(function()
        return require("bos_online").forBook({ title = b.title, authors = b.authors or {}, series = b.series_name })
    end)
    self.items = ok and list or {}
    -- their covers, fetched now if they aren't on file (only the first page's:
    -- nothing is downloaded for covers nobody looks at)
    if not self._covers_asked and #self.items > 0 then
        self._covers_asked = true
        local first = {}
        for i = 1, math.min(6, #self.items) do first[i] = self.items[i] end
        pcall(function()
            require("bos_online").fetchCovers(first, function()
                if self.dimen and self.dimen.x then self:load() self:redraw() end
            end, 6)
        end)
    end
end

function RecsTab:getSize() return Geom:new{ w = self.width, h = self.height } end

function RecsTab:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    self.hits = {}
    local pad = S(18)
    local w = self.width - 2 * pad
    bb:paintRect(x, y, self.width, self.height, WHITE)
    local items = self.items
    if #items == 0 then
        local Online = require("bos_online")
        local msg = not Online.enabled() and _("Recommendations are turned off (Settings → Connect → Recommendations).")
            or _("No recommendations yet. They come from what you read, over Wi-Fi.")
        local h = require("bos_page").wrap(bb, msg, Look.serif(17, false, true), x + pad, y + S(24), w, 4, S(26), Look.GRAY)
        if Online.enabled() then
            local r = Look.button(bb, x + pad, y + S(24) + h + S(18), S(280), S(50), _("Get recommendations"), { size = 13, on = true })
            table.insert(self.hits, { rect = r, fn = function() Online.setup() end })
        end
        return
    end
    -- big covers: three across, as many rows as fit (the titles under them)
    local cols, gap = 3, S(22)
    local foot = S(58)
    local cw = math.floor((w - (cols - 1) * gap - Look.SHADOW_SMALL) / cols)
    local ch = math.floor(cw * 1.5)
    local label_h = S(48)
    local rh = ch + S(8) + label_h + S(12)
    local rows = math.max(1, math.floor((self.height - S(14) - foot) / rh))
    if rows == 1 and ch + S(8) + label_h > self.height - S(14) - foot then
        -- a short window: smaller covers rather than none
        ch = math.max(S(90), self.height - S(14) - foot - S(8) - label_h)
        cw = math.floor(ch / 1.5)
        cols = math.max(3, math.floor((w + gap) / (cw + gap)))
    end
    local per = rows * cols
    local pages = math.max(1, math.ceil(#items / per))
    self.page = math.max(1, math.min(self.page, pages))
    local first = (self.page - 1) * per
    local Online = require("bos_online")
    for k = 1, per do
        local it = items[first + k]
        if not it then break end
        local cx = x + pad + ((k - 1) % cols) * (cw + gap)
        local cy = y + S(14) + math.floor((k - 1) / cols) * rh
        Look.box(bb, cx, cy, cw, ch, { shadow = Look.SHADOW_SMALL, border = math.max(1, S(1)) })
        local drawn = false
        if it.cover_path then
            local okI, img = pcall(function()
                return require("ui/renderimage"):renderImageFile(it.cover_path, false, cw - 2, ch - 2)
            end)
            if okI and img then
                bb:blitFrom(img, cx + math.floor((cw - img:getWidth()) / 2), cy + math.floor((ch - img:getHeight()) / 2),
                    0, 0, img:getWidth(), img:getHeight())
                img:free()
                drawn = true
            end
        end
        if not drawn then
            local fs = math.max(10, math.floor(cw / 9))
            require("bos_page").wrap(bb, it.title or "", Look.serif(fs, true), cx + S(8), cy + S(10), cw - S(16), 5, math.floor(fs * 1.5))
        end
        if it.owned then Online.paintBadge(bb, cx + 1, cy, cw - 2, ch - 1) end
        local th = require("bos_page").wrap(bb, it.title or "", tface(13, true), cx, cy + ch + S(8), cw, 2, S(19))
        if it.author and it.author ~= "" then
            require("bos_page").wrap(bb, it.author, Look.serif(12, false, true), cx, cy + ch + S(8) + th, cw, 1, S(18), Look.GRAY)
        end
        table.insert(self.hits, { rect = Geom:new{ x = cx - S(6), y = cy - S(6), w = cw + S(12), h = rh - S(4) },
            press = Geom:new{ x = cx, y = cy, w = cw, h = ch }, fn = function() self:open(it) end })
    end
    if pages > 1 then
        local fh, kw = S(40), S(64)
        local fy = y + self.height - fh - S(10)
        local rp = Look.button(bb, x + pad, fy, kw, fh, "\u{2039}", { size = 16, enabled = self.page > 1 })
        if self.page > 1 then table.insert(self.hits, { rect = rp, fn = function() self.page = self.page - 1 self:redraw() end }) end
        local rn = Look.button(bb, x + pad + w - kw - Look.SHADOW_SMALL, fy, kw, fh, "\u{203A}", { size = 16, enabled = self.page < pages })
        if self.page < pages then table.insert(self.hits, { rect = rn, fn = function() self.page = self.page + 1 self:redraw() end }) end
        Look.label(bb, T(_("%1 / %2"), self.page, pages), x + pad + kw, fy, w - 2 * kw, fh, 12, { align = "center" })
    end
end

function RecsTab:redraw()
    if self.dimen and self.dimen.x then
        UIManager:setDirty(self.show_parent or "all", function() return "ui", self.dimen end)
    end
end

--- A recommendation tapped: the window closes, and the store opens on it
--- (or your own copy's window, when it's in your library).
function RecsTab:open(it)
    local modal = self.modal and self.modal()
    local item = it.pick or it
    UIManager:nextTick(function()
        if modal then pcall(function() if modal.onClose then modal:onClose() else UIManager:close(modal) end end) end
        UIManager:nextTick(function()
            local ok, err = pcall(function() require("bos_online").showSheet(item) end)
            if not ok then logger.warn("ShelfTechUI: opening a recommendation:", err) end
        end)
    end)
end

function RecsTab:onRTap(_, ges)
    for k = #self.hits, 1, -1 do
        local h = self.hits[k]
        if inside(ges.pos, h.rect) then
            UI.press(h.press or h.rect, h.fn)
            return true
        end
    end
    return false
end

M.RecsTab = RecsTab

--- The tab for Bookshelf's book window (a book of yours, not a remote one).
function M.recsTab(bw, book, modal)
    if type(book) ~= "table" or type(book.filepath) ~= "string" or book.is_remote or book.is_folder then return nil end
    local okS, Sources = pcall(require, "lib/bookshelf_sources")
    if okS and Sources.isRemotePath and Sources.isRemotePath(book.filepath) then return nil end
    return {
        id = "stui_recs",
        label = _("Recommendations"),
        widget_builder = function(avail_w, avail_h, show_parent)
            return RecsTab:new{ width = avail_w, height = avail_h, book = book, modal = modal, show_parent = show_parent }
        end,
    }
end

return M
