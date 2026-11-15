--[[
Micro-module: the readers you follow on Hardcover, as a friends list (the
way a console lists who's online and what they're playing): each reader's
name, the book they're on, and how far along they are. Those reading now
come first; a reader with nothing on the go shows the last book they
finished.

It draws from what ShelfTechUI last fetched (bos_hardcover keeps it on the
device), so it never waits on the network; when that's older than a quarter
of an hour and Wi-Fi is on, it's fetched again in the background and the
card redraws. A tap on a reader opens their page; a tap elsewhere, the
Hardcover app's Friends tab.

Hardcover knows the page a reader is on, not the chapter: that's what's
shown ("42% · page 130").
]]
local _ = require("lib/bookshelf_i18n").gettext
local T = require("ffi/util").template

local function HC()
    local ok, m = pcall(require, "bos_hardcover")
    return ok and m or nil
end

local function line(row)
    local parts = { row.book.title }
    if row.percent then parts[#parts + 1] = T(_("%1%"), row.percent) end
    if row.page and row.page > 0 then parts[#parts + 1] = T(_("page %1"), row.page) end
    return table.concat(parts, "  ·  ")
end

return {
    key     = "stui_hardcover_friends", -- stable id stored in user menus; never change it
    min_w   = 2,
    title   = _("Friends reading"),
    summary = _("Who you follow on Hardcover: what they're reading and how far."),
    tap_feedback = true,

    render = function(ctx)
        local Kit = require("lib/bookshelf_module_kit")
        local TextWidget = require("lib/bookshelf_colour_text")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan = require("ui/widget/verticalspan")
        local sc = Kit.sc(ctx.scale)
        local mw = math.max(50, ctx.width)
        local H = HC()
        local function note(text)
            return VerticalGroup:new{ align = "left",
                TextWidget:new{ text = _("Friends reading"), face = (Kit.face(15, ctx.scale, { bold = true })), bold = true,
                    fgcolor = Kit.COLOR_MUTED, max_width = mw },
                VerticalSpan:new{ width = sc(4) },
                TextWidget:new{ text = text, face = Kit.face(13, ctx.scale), fgcolor = Kit.COLOR_MUTED, max_width = mw } }
        end
        if not H or not H.signedIn() then return note(_("Sign in to Hardcover to see them.")) end
        local people = H.socialCached().people or {}
        -- (fresh for the next look; redraws this card when it arrives)
        if not ctx.preview then pcall(H.socialTouch, ctx.refresh) end
        if #people == 0 then return note(_("Nobody yet: follow readers on hardcover.app.")) end

        local fname, bname = Kit.face(15, ctx.scale, { bold = true })
        local fbook = Kit.face(13, ctx.scale, { italic = true })
        local name_h = TextWidget:new{ text = "Ag", face = fname, bold = bname }:getSize().h
        local book_h = TextWidget:new{ text = "Ag", face = fbook }:getSize().h
        local gap = sc(8)
        local row_h = name_h + book_h + gap
        local cap = ctx.height or ctx.max_height
        local n = 4
        if cap and cap > 0 then n = math.max(1, math.floor((cap + gap) / row_h)) end
        local group, regions = VerticalGroup:new{ align = "left" }, {}
        local y = 0
        for i = 1, math.min(n, #people) do
            local who = people[i]
            local row = who.reading and who.reading[1]
            local last = not row and who.finished and who.finished[1]
            -- ● reading now, ○ not
            local name = (row and "\u{25CF} " or "\u{25CB} ") .. (who.name or who.username or "?")
            local what = row and line(row) or (last and T(_("Finished %1"), last.book.title)) or _("Nothing lately")
            if i > 1 then group[#group + 1] = VerticalSpan:new{ width = gap } y = y + gap end
            group[#group + 1] = TextWidget:new{ text = name, face = fname, bold = bname, fgcolor = Kit.COLOR_PRIMARY, max_width = mw }
            group[#group + 1] = TextWidget:new{ text = what, face = fbook, fgcolor = row and Kit.COLOR_PRIMARY or Kit.COLOR_MUTED, max_width = mw }
            regions[#regions + 1] = { id = tostring(who.id), x = 0, y = y, w = mw, h = name_h + book_h }
            y = y + name_h + book_h
        end
        if ctx.set_tap_regions then ctx.set_tap_regions(regions) end
        return group
    end,

    on_tap = function(ctx)
        local H = HC()
        if not H then return end
        local ok, HUI = pcall(require, "bos_hardcover_ui")
        if not ok then return end
        local id = ctx and ctx.tapped_region and tonumber(ctx.tapped_region)
        if id and H.signedIn() then
            for _i, who in ipairs(H.socialCached().people or {}) do
                if who.id == id then HUI.openProfile(who) return end
            end
        end
        HUI.open(H.signedIn() and "friends" or nil)
    end,
}
