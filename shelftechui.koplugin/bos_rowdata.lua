--[[
What the toolbar's bottom row shows under each key (GLIMPSE · PIN · STATS):

  GLIMPSE  the pictures you've passed so far, of those in the book ("3 OF 12")
  PIN      how many pages of this book are pinned
  STATS    one reading figure, a different one each time the toolbar opens:
           your streak, today, this week, the chapter's time left, your pace,
           books this year

Everything here is cheap and cached; nothing that isn't known yet is guessed
(a figure with no data is skipped, an unscanned book shows "…").
--]]

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

-- ---------------------------------------------------------------- glimpse

--- Glimpse can look at this book (EPUB, FB2, MOBI; not PDFs or comics).
function M.glimpseWorks(ui)
    local g = ui and ui.glimpse
    if not (g and g._docFormat) then return false end
    local ok, fmt = pcall(g._docFormat, g)
    return ok and fmt ~= nil and fmt ~= "other"
end

--- { seen, total }: Glimpse's pictures (as its viewer counts them: its filter,
--- your hidden and added ones) before here, and in the whole book. nil while
--- the book hasn't been scanned; `scan` scans it first.
function M.glimpse(ui, scan)
    local g = ui and ui.glimpse
    if not M.glimpseWorks(ui) then return nil end
    local ok, res = pcall(g.counts, g, scan)
    if not ok then logger.warn("ShelfTechUI: Glimpse count failed:", res) return nil end
    return res
end

-- ---------------------------------------------------------------- pins

function M.pins(ui)
    local ok, n = pcall(function() return #require("bos_pins").list(ui) end)
    return ok and n or 0
end

-- ---------------------------------------------------------------- stats

local figs = { at = 0 }

--- Streak, today, this week, books this year (KOReader's statistics), for a minute.
local function figures()
    local now = os.time()
    if figs.f ~= nil and now - figs.at < 60 then return figs.f or nil end
    local ok, f = pcall(function() return require("bos_summary").figures() end)
    figs.at, figs.f = now, (ok and f) or false
    return figs.f or nil
end

local turn = 0

--- Next time the toolbar opens, the next figure.
function M.advance() turn = turn + 1 end

--- Every figure that has something to say, in rotation order.
function M.statsList(ui, page)
    local Reading = require("bos_reading")
    local out = {}
    local f = figures()
    if f and f.streak and f.streak > 0 then
        table.insert(out, T(_("%1-day streak"), f.streak))
    end
    if f and f.today and f.today >= 60 then table.insert(out, T(_("%1 today"), Reading.hm(f.today))) end
    local st = ui.statistics
    local avg = st and st.settings and st.settings.is_enabled and st.avg_time
    if avg and avg == avg and avg > 0 then
        local okC, left = pcall(Reading.chapterPagesLeft, ui, page)
        if okC and left and left > 1 then
            table.insert(out, T(_("%1 left in ch."), Reading.hm((left - 1) * avg)))
        end
        local pph = math.floor(3600 / avg + 0.5)
        if pph > 0 and pph < 1000 then table.insert(out, T(_("%1 pages/hr"), pph)) end
    end
    if f and f.week and f.week >= 60 then table.insert(out, T(_("%1 this week"), Reading.hm(f.week))) end
    if f and f.books_year and f.books_year > 0 then
        table.insert(out, T(_.ngettext("1 book this year", "%1 books this year", f.books_year), f.books_year))
    end
    return out
end

--- This opening's figure (or nil when there's none at all).
function M.stat(ui, page)
    local ok, list = pcall(M.statsList, ui, page)
    if not ok then logger.warn("ShelfTechUI: stats figure failed:", list) return nil end
    if #list == 0 then return nil end
    return list[turn % #list + 1]
end

return M
