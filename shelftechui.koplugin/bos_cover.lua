--[[
Covers at display size (Aleph idea E3): each cover is decoded once, scaled to
the size it is shown at, and kept in a small LRU, so the toolbar's book card,
the Also reading strip and the book pages never rescale on a repaint.

  get(filepath, w, h, ui) -> bb (owned by the cache: don't free) or nil
  paint(bb, filepath, x, y, w, h, opts) -> true when a cover was drawn;
      otherwise a pinstriped placeholder with the title is drawn.

Sources, in order: Bookshelf's own scaled cover cache, Bookshelf's repository
(KOReader's book info database), the open document's first page.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local M = {}

-- (Read and Dash on home show up to ~30 covers at once)
local MAX = 40
local cache, order = {}, {}

local function touch(key)
    for i, k in ipairs(order) do
        if k == key then table.remove(order, i) break end
    end
    table.insert(order, key)
    while #order > MAX do
        local old = table.remove(order, 1)
        local e = cache[old]
        cache[old] = nil
        if e and e.bb then pcall(function() e.bb:free() end) end
    end
end

--- Scaled to fit w x h, aspect kept.
local function fit(src, w, h)
    local sw, sh = src:getWidth(), src:getHeight()
    if sw <= 0 or sh <= 0 then return nil end
    local scale = math.min(w / sw, h / sh)
    local tw, th = math.max(1, math.floor(sw * scale + 0.5)), math.max(1, math.floor(sh * scale + 0.5))
    local RenderImage = require("ui/renderimage")
    local out = RenderImage:scaleBlitBuffer(src, tw, th, false)
    if out == src then out = src:copy() end
    return out
end

local function decode(filepath, ui)
    -- Bookshelf's scaled cache (shared: not ours to free)
    local ok, SCC = pcall(require, "lib/bookshelf_scaled_cover_cache")
    if ok and SCC and SCC.get then
        local okg, bb = pcall(SCC.get, SCC, filepath)
        if okg and bb then return bb, false end
    end
    local okR, Repo = pcall(require, "lib/bookshelf_book_repository")
    if okR and Repo and Repo.getCoverBB then
        local okc, bb = pcall(Repo.getCoverBB, filepath)
        if okc and bb then return bb, true end
    end
    local okB, BIM = pcall(require, "bookinfomanager")
    if okB and BIM and BIM.getBookInfo then
        local oki, info = pcall(BIM.getBookInfo, BIM, filepath, true)
        if oki and info and info.cover_bb and not info.ignore_cover then return info.cover_bb, true end
    end
    if ui and ui.document and ui.document.file == filepath and ui.document.getCoverPageImage then
        local okd, bb = pcall(ui.document.getCoverPageImage, ui.document)
        if okd and bb then return bb, true end
    end
    return nil
end

function M.get(filepath, w, h, ui)
    if not filepath then return nil end
    local key = filepath .. "@" .. w .. "x" .. h
    local e = cache[key]
    if e then touch(key) return e.bb end
    local bb
    local ok, err = pcall(function()
        local src, owned = decode(filepath, ui)
        if src then
            bb = fit(src, w, h)
            if owned then src:free() end
        end
    end)
    if not ok then logger.warn("ShelfTechUI: cover failed:", err) end
    cache[key] = { bb = bb }
    touch(key)
    return bb
end

--- Forget one book's covers (its cover was changed).
function M.forget(filepath)
    for key, e in pairs(cache) do
        if key:sub(1, #filepath + 1) == filepath .. "@" then
            cache[key] = nil
            for i, k in ipairs(order) do if k == key then table.remove(order, i) break end end
            if e.bb then pcall(function() e.bb:free() end) end
        end
    end
end

--- Draws the cover in a box of w x h (2px outline, hard shadow `shadow`),
--- centred if its aspect differs; a pinstriped card with the title if none.
function M.paint(bb, filepath, x, y, w, h, opts)
    opts = opts or {}
    local Look = require("bos_look")
    local sh = opts.shadow or Look.SHADOW_SMALL
    local line = opts.border or Look.LINE
    local cover = M.get(filepath, w - 2 * line, h - 2 * line, opts.ui)
    if cover then
        local cw, ch = cover:getWidth() + 2 * line, cover:getHeight() + 2 * line
        local cx, cy = x + math.floor((w - cw) / 2), y + (h - ch)
        if sh > 0 then Look.shadow(bb, cx, cy, cw, ch, sh) end
        bb:paintRect(cx, cy, cw, ch, Look.INK)
        bb:blitFrom(cover, cx + line, cy + line, 0, 0, cover:getWidth(), cover:getHeight())
        return true
    end
    Look.box(bb, x, y, w, h, { shadow = sh, border = line })
    Look.stripes(bb, x + line + 2, y + line + 2, w - 2 * line - 4, math.floor(h * 0.3))
    if opts.title and w > 40 then
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local Font = require("ui/font")
        local tb = TextBoxWidget:new{ text = opts.title, width = w - 2 * line - 8,
            face = require("bos_look").serif(math.max(7, math.floor(w / 8)), true),
            alignment = "center", height = math.floor(h * 0.6), height_overflow_show_ellipsis = true }
        tb:paintTo(bb, x + line + 4, y + math.floor(h * 0.36))
        tb:free()
    end
    return false
end

return M
