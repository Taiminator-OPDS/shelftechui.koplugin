--[[
A book's page, as a retro window over the list:

    [■]≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡[ BOOK ]≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡≡
    ▉▉▉▉   Pride and Prejudice
    ▉▉▉▉   by Jane Austen
    ▉▉▉▉   [PROJECT GUTENBERG]
           EPUB · EN · 1813
    DOWNLOAD ........................ [COVER ›]
    [ EPUB   1.2 MB ]  [ MOBI   0.9 MB ]
    ABOUT THIS BOOK ...........................
    The description, then the edition's details;
    this part scrolls (swipe or tap its edges).

Everything else stays put, so the buttons are always where the eye expects.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Style = require("bookdrop_style")
local S = Style.S
local Screen = Device.screen

local BookView = InputContainer:extend{
    name = "bookdrop_book",
    modal = true,
    book = nil,
    download_callback = nil,
    cover_download_callback = nil,
}

local function join(values)
    local present = {}
    for _i, value in ipairs(values) do
        if value and value ~= "" then present[#present + 1] = tostring(value) end
    end
    return table.concat(present, "  \u{00B7}  ")
end

local function cleanDescription(value)
    value = value or ""
    value = value:gsub("\r\n?", "\n")
    value = value:gsub("<[bB][rR]%s*/?>", "\n")
    value = value:gsub("</[pP]%s*>", "\n\n")
    value = value:gsub("<[^>]+>", "")
    local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
    value = value:gsub("&([%a]+);", function(entity) return entities[entity] or ("&" .. entity .. ";") end)
    value = value:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
    value = value:gsub("%[([^%]]+)%]%[%d+%]", "%1")
    value = value:gsub("%[%d+%]:%s*https?://%S+", "")
    value = value:gsub("^SUMMARY:%s*", "")
    value = value:gsub("[ \t]+", " ")
    value = value:gsub(" *\n *", "\n")
    value = value:gsub("\n\n\n+", "\n\n")
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function concise(value, maximum)
    if value == nil then return nil end
    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    if maximum and #value > maximum then
        return value:sub(1, maximum - 1):gsub("%s+%S*$", "") .. "…"
    end
    return value
end

local function addMetadata(lines, label, value, maximum)
    value = concise(value, maximum)
    if value then lines[#lines + 1] = label .. ":  " .. value end
end

local function acquisitionSize(acquisition)
    if not acquisition or not acquisition.size then return nil end
    local bytes = tonumber(acquisition.size)
    if not bytes then return nil end
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / 1024 / 1024) end
    return string.format("%.0f KB", bytes / 1024)
end

function BookView:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.cover_cache = {}
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    local book = self.book

    local win_w = math.floor(sw * 0.94) - Style.SHADOW
    local win_h = math.floor(sh * 0.92) - Style.SHADOW
    local inner = win_w - 2 * Style.LINE
    local m = S(18)
    local w = inner - 2 * m

    local strip = Style.TitleStrip{ width = inner, caption = _("Book"), height = S(34),
        on_close = function() self:onClose() end }

    -- hero: the cover, and the facts beside it
    local cover_w = math.floor(w * 0.32)
    local cover_h = math.floor(cover_w * 1.45)
    local info_w = w - cover_w - Style.SHADOW - S(18)
    local hero = Style.Painted:new{
        width = w, height = cover_h + Style.SHADOW,
        draw = function(_p, bb, x, y)
            Style.drawCover(bb, book, x, y, cover_w, cover_h, self.cover_cache)
            local tx = x + cover_w + Style.SHADOW + S(18)
            local face, bold = Style.face(22, true)
            local t = TextBoxWidget:new{ text = book.title or _("Untitled"), width = info_w, face = face, bold = bold,
                height = S(90), height_overflow_show_ellipsis = true }
            t:paintTo(bb, tx, y)
            local ty = y + math.min(t:getSize().h, S(90)) + S(6)
            t:free()
            if book.subtitle and book.subtitle ~= "" then
                Style.text(bb, book.subtitle, tx, ty, info_w, S(22), { size = 15, color = Style.GRAY })
                ty = ty + S(24)
            end
            Style.text(bb, _("by") .. " " .. (book.author or _("Unknown author")), tx, ty, info_w, S(26),
                { face = Style.italic(17) })
            ty = ty + S(36)
            local src = Style.case(tostring(book.source or _("Catalog")))
            local sf = Style.mono(12)
            local cw = math.min(info_w, Style.textWidth(src, sf, true) + S(18))
            Style.box(bb, tx, ty, cw, S(26), { border = math.max(1, S(1.5)) })
            Style.text(bb, src, tx, ty, cw, S(26), { face = sf, bold = true, align = "center" })
            ty = ty + S(36)
            local facts = join({ book.available_formats or book.format, book.language,
                book.published_date or book.year })
            if facts ~= "" then
                local fb = TextBoxWidget:new{ text = Style.case(facts), width = info_w, face = Style.mono(12), bold = true,
                    fgcolor = Style.GRAY, height = S(40), height_overflow_show_ellipsis = true }
                fb:paintTo(bb, tx, ty)
                fb:free()
            end
        end,
    }

    -- downloads
    local acquisitions = (self.download_callback and book.acquisitions) or {}
    local dl_label = Style.LabelLine(_("Download"), w, self.cover_download_callback and _("Cover") or nil,
        self.cover_download_callback, { height = S(38) })
    local btn_h = S(46)
    local btn_gap = S(14)
    local btn_w = math.floor((w - btn_gap - Style.SHADOW) / 2)
    local rows = math.ceil(#acquisitions / 2)
    local downloads = Style.Painted:new{
        width = w, height = math.max(S(30), rows * (btn_h + S(12))),
        draw = function(p, bb, x, y)
            p.rects = {}
            if #acquisitions == 0 then
                Style.text(bb, _("This library did not return a compatible public file."), x, y, w, S(30),
                    { face = Style.italic(15), color = Style.GRAY })
                return
            end
            for i, acq in ipairs(acquisitions) do
                local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
                local bx = x + col * (btn_w + btn_gap)
                local by = y + row * (btn_h + S(12))
                local down = p.pressed == i
                local ox = down and Style.SHADOW or 0
                Style.box(bb, bx + ox, by + ox, btn_w, btn_h, { shadow = down and 0 or Style.SHADOW,
                    fill = down and Style.BLACK or Style.WHITE })
                local ink = down and Style.WHITE or Style.BLACK
                Style.text(bb, Style.GLYPH.download, bx + ox + S(12), by + ox, S(20), btn_h,
                    { face = Style.symbol(13), color = ink })
                local fmt = tostring(acq.format or _("Ebook")):upper()
                local fw = Style.text(bb, fmt, bx + ox + S(38), by + ox, btn_w - S(48), btn_h,
                    { face = Style.mono(16), bold = true, color = ink })
                local size = acquisitionSize(acq)
                if size then
                    Style.text(bb, size, bx + ox + S(38) + fw + S(10), by + ox, btn_w - fw - S(58), btn_h,
                        { face = Style.mono(13), color = down and Style.WHITE or Style.GRAY })
                end
                p.rects[i] = Geom:new{ x = bx, y = by, w = btn_w + Style.SHADOW, h = btn_h + Style.SHADOW }
            end
        end,
        tap = function(p, pos)
            for i, r in pairs(p.rects or {}) do
                if Style.inside(pos, r) then
                    local acq = acquisitions[i]
                    p:press(i, function()
                        p:repaint("ui")
                        self.download_callback(acq)
                    end)
                    return true
                end
            end
            return true
        end,
    }

    -- about: description, then the edition's details (scrolls)
    local description = cleanDescription(book.description)
    if description == "" then description = _("No description supplied for this edition.") end
    local lines = {}
    addMetadata(lines, _("Publisher"), book.publisher)
    addMetadata(lines, _("Published"), book.published_date or book.year)
    addMetadata(lines, _("Originally published"), book.original_publication_date)
    addMetadata(lines, _("Publication place"), book.publication_place)
    addMetadata(lines, _("Edition"), book.edition)
    addMetadata(lines, _("Series"), book.series)
    addMetadata(lines, _("Volume"), book.volume)
    addMetadata(lines, _("Language"), book.language)
    addMetadata(lines, _("Pages / scanned images"), book.page_count)
    addMetadata(lines, _("ISBN"), book.isbn, 180)
    addMetadata(lines, _("Available formats"), book.available_formats)
    addMetadata(lines, _("Subjects"), book.subjects, 500)
    addMetadata(lines, _("Contributors"), book.contributors, 300)
    addMetadata(lines, _("Notes"), book.notes, 800)
    addMetadata(lines, _("Downloads"), book.downloads)
    addMetadata(lines, _("Rights / license"), book.rights, 400)
    addMetadata(lines, _("Catalog record"), book.id)
    local about_text = description
    if #lines > 0 then
        about_text = about_text .. "\n\n" .. _("EDITION") .. "\n" .. table.concat(lines, "\n")
    end
    local about_label = Style.LabelLine(_("About this book"), w, nil, nil, { height = S(38) })

    local fixed = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = S(14) },
        hero,
        VerticalSpan:new{ width = S(14) },
        dl_label,
        VerticalSpan:new{ width = S(6) },
        downloads,
        VerticalSpan:new{ width = S(6) },
        about_label,
        VerticalSpan:new{ width = S(4) },
    }
    local about_h = win_h - 2 * Style.LINE - strip.height - fixed:getSize().h - S(14)
    local face = Style.face(16)
    local about = ScrollTextWidget:new{
        text = about_text, face = face, width = w, height = math.max(S(80), about_h),
        dialog = self, justified = false,
    }
    table.insert(fixed, about)
    fixed:resetLayout()
    local window = FrameContainer:new{
        bordersize = Style.LINE, color = Style.BLACK, radius = 0, padding = 0, margin = 0,
        background = Style.WHITE,
        VerticalGroup:new{
            align = "left",
            strip,
            HorizontalGroup:new{ HorizontalSpan:new{ width = m }, fixed },
        },
    }
    self.window = window
    local ws = window:getSize()
    self.panel_dimen = Geom:new{ x = math.floor((sw - ws.w - Style.SHADOW) / 2),
        y = math.floor((sh - ws.h - Style.SHADOW) / 2), w = ws.w, h = ws.h }
    self.paint_dimen = Geom:new{ x = self.panel_dimen.x, y = self.panel_dimen.y,
        w = ws.w + Style.SHADOW, h = ws.h + Style.SHADOW }
    self[1] = window
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen:copy() } },
    }
end

function BookView:paintTo(bb)
    local r = self.panel_dimen
    Style.shadow(bb, r.x, r.y, r.w, r.h)
    self.window:paintTo(bb, r.x, r.y)
end

function BookView:onTapClose(_, ges)
    if ges.pos:notIntersectWith(self.panel_dimen) then self:onClose() end
    return true
end

function BookView:onShow()
    Style.fullRefresh(self)
    return true
end

function BookView:onCloseWidget()
    Style.freeCache(self.cover_cache)
    -- back to the list: repaint it all and refresh the whole screen
    UIManager:setDirty(nil, "full")
end

function BookView:onClose()
    UIManager:close(self)
    return true
end

return BookView
