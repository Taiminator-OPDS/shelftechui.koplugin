--[[
Start-menu module (ShelfTechUI): a word of the day from KOReader's Vocabulary
builder, one you looked up while reading, with its sentence. Tap: the word in
a sheet (LOOK UP, ANOTHER WORD). Says so when the Vocabulary builder has no
words yet.
]]
local _ = require("lib/bookshelf_i18n").gettext

return {
    key = "stui_word_of_day", -- stable id stored in user menus; never change it
    min_w = 2,
    title = _("Word of the day"),
    summary = _("A word you looked up (Vocabulary builder), with its sentence."),
    render = function(ctx)
        local Fonts = require("lib/bookshelf_fonts")
        local TextWidget = require("lib/bookshelf_colour_text")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local SM = require("lib/bookshelf_start_menu_modules")
        local Kit = require("lib/bookshelf_module_kit")
        local mw = math.max(50, ctx.width)
        local function sc(n) return math.max(1, math.floor(n * (ctx.scale or 100) / 100 + 0.5)) end
        local w = require("bos_daily").wordOfDay()
        if not w then
            return TextWidget:new{ text = _("No looked-up words yet"), face = Fonts:getFace("cfont", sc(15)),
                fgcolor = SM.COLOR_MUTED, max_width = mw }
        end
        local face, bold = Fonts:getFace("cfont", sc(22), { bold = true })
        local g = VerticalGroup:new{ align = "left",
            TextWidget:new{ text = w.word, face = face, bold = bold, fgcolor = SM.COLOR_PRIMARY, max_width = mw } }
        if w.context then
            local room = ctx.height or ctx.max_height
            table.insert(g, Kit.fitText{ text = w.context, size = 14, scale_pct = ctx.scale, width = mw,
                max_h = room and math.max(1, room - g:getSize().h) or nil, fgcolor = Kit.COLOR_MUTED,
                opts = { italic = true } })
        end
        return g
    end,
    on_tap = function()
        local Daily = require("bos_daily")
        Daily.showWord(Daily.wordOfDay())
    end,
}
