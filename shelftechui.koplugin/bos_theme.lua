--[[
ShelfTechUI's themes: the whole interface in one of six looks. A theme is a
table of design decisions that bos_look (and the few screens that draw for
themselves) read instead of fixed values, so a theme costs nothing extra to
draw. The book's own page is never themed: it keeps your reading font.

  retro      square 2px boxes, hard black shadows, pinstripes, mono capitals
  modern     rounded cards, a soft grey lift, pill tracks, sans in plain case
  fantasy    double rules with a hairline frame, Roman capitals, a diamond handle
  scifi      hairline frames with corner brackets, segmented meters, terminal type
  rustic     stitched seams, worn corners, grey shadows, slab serif
  book       pages with the page block at their edge, dog-ears, a ribbon handle

The theme is read once, when KOReader starts (Settings → Themes asks to
restart after a change).

Fields:
  chrome     the face for controls: "infont" (KOReader's), or a .ttf in fonts/
  synth      embolden the chrome face (KOReader's infont is regular)
  upper      controls in capitals
  serif      book-title faces { regular, bold, italic, bolditalic } (nil: Noto Serif)
  text       the reading-UI face (lists, rows, Bookshelf's home, dialogs), same
             shape (nil: Bookshelf's chosen font, as without themes)
  line       outline width (unscaled px)
  frame      square | round | double | brackets | stitched | page
  radius     corner radius (round, stitched)
  shadow     hard | soft | none | pages
  shade      the shadow's colour
  ink        outlines;  paper: box fill;  press: a pressed or "on" key
  band       title-strip decoration: stripes | none | double | ticks | dashed | rule
  fill       a bar's empty part: stripes | solid | segments | hatch
  track      stripes | pill | line | segments | groove | ribbon
  knob       square | round | diamond | bar | ribbon
  glyph      icon stroke weight (1 = retro)
--]]

local Blitbuffer = require("ffi/blitbuffer")
local _ = require("gettext")

local B, W = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = {}

M.ORDER = { "retro", "modern", "fantasy", "scifi", "rustic", "book" }

M.THEMES = {
    retro = {
        name = _("Retro"),
        desc = _("Today's look: square boxes with a 2px outline and a hard black shadow, pinstripes, monospaced bold capitals."),
        chrome = "infont", synth = true, upper = true,
        line = 2, frame = "square", radius = 0, shadow = "hard", shade = B,
        ink = B, paper = W, press = B,
        band = "stripes", fill = "stripes", track = "stripes", knob = "square", glyph = 1,
    },
    modern = {
        name = _("Modern"),
        desc = _("Quiet and soft: rounded cards with a light grey lift, pill tracks with a round handle, sans-serif in plain case."),
        chrome = "NotoSans-Bold.ttf", synth = false, upper = false,
        text = { regular = "NotoSans-Regular.ttf", bold = "NotoSans-Bold.ttf", italic = "NotoSans-Italic.ttf",
            bolditalic = "NotoSans-BoldItalic.ttf" },
        serif = { regular = "NotoSans-Regular.ttf", bold = "Inter-ExtraBold.ttf", italic = "NotoSans-Italic.ttf",
            bolditalic = "Inter-ExtraBold.ttf" },
        line = 1.5, frame = "round", radius = 12, shadow = "soft", shade = Blitbuffer.COLOR_GRAY_D,
        ink = Blitbuffer.COLOR_GRAY_B, paper = W, press = B,
        band = "none", fill = "solid", track = "pill", knob = "round", glyph = 0.8,
    },
    fantasy = {
        name = _("Fantasy"),
        desc = _("An old book's frontispiece: engraved double rules with a hairline frame, Roman capitals, Garamond italics, a diamond handle."),
        chrome = "stui-Cinzel-Bold.ttf", synth = false, upper = true,
        text = { regular = "stui-EBGaramond-Regular.ttf", bold = "stui-EBGaramond-SemiBold.ttf",
            italic = "stui-EBGaramond-Italic.ttf", bolditalic = "stui-EBGaramond-SemiBoldItalic.ttf" },
        serif = { regular = "stui-EBGaramond-Italic.ttf", bold = "stui-EBGaramond-SemiBoldItalic.ttf",
            italic = "stui-EBGaramond-Italic.ttf", bolditalic = "stui-EBGaramond-SemiBoldItalic.ttf" },
        line = 4, frame = "double", radius = 0, shadow = "none", shade = B,
        ink = B, paper = W, press = B,
        band = "double", fill = "solid", track = "line", knob = "diamond", glyph = 0.7,
    },
    scifi = {
        name = _("Sci-fi"),
        desc = _("A ship's console: hairline frames with heavy corner brackets, segmented meters, wide terminal type, Orbitron titles."),
        chrome = "ShareTechMono-Regular.ttf", synth = false, upper = true,
        text = { regular = "ShareTechMono-Regular.ttf", bold = "Orbitron-Variable.ttf",
            italic = "ShareTechMono-Regular.ttf", bolditalic = "Orbitron-Variable.ttf" },
        serif = { regular = "ShareTechMono-Regular.ttf", bold = "Orbitron-Variable.ttf",
            italic = "ShareTechMono-Regular.ttf", bolditalic = "Orbitron-Variable.ttf" },
        line = 1, frame = "brackets", radius = 0, shadow = "none", shade = B,
        ink = B, paper = W, press = B,
        band = "ticks", fill = "segments", track = "segments", knob = "bar", glyph = 0.7,
    },
    rustic = {
        name = _("Rustic"),
        desc = _("A cabin bookshelf: slab serif in plain case, stitched seams, slightly worn corners, warm grey shadows, a round wooden handle."),
        chrome = "stui-ZillaSlab-SemiBold.ttf", synth = false, upper = false,
        text = { regular = "stui-ZillaSlab-Regular.ttf", bold = "stui-ZillaSlab-Bold.ttf",
            italic = "stui-ZillaSlab-Italic.ttf", bolditalic = "stui-ZillaSlab-Bold.ttf" },
        serif = { regular = "stui-ZillaSlab-SemiBold.ttf", bold = "stui-ZillaSlab-Bold.ttf",
            italic = "stui-ZillaSlab-Italic.ttf", bolditalic = "stui-ZillaSlab-Bold.ttf" },
        line = 2, frame = "stitched", radius = 7, shadow = "hard", shade = Blitbuffer.COLOR_GRAY_9,
        ink = Blitbuffer.COLOR_GRAY_3, paper = W, press = Blitbuffer.COLOR_GRAY_4,
        band = "dashed", fill = "hatch", track = "groove", knob = "round", glyph = 0.9,
    },
    book = {
        name = _("Book"),
        desc = _("Everything part of a bound book: pages with the page block at their edge, dog-eared keys, thumb-index tabs, a ribbon-bookmark handle, Caslon and small capitals."),
        chrome = "stui-CormorantSC-Bold.ttf", synth = false, upper = false,
        text = { regular = "stui-LibreCaslonText-Regular.ttf", bold = "stui-LibreCaslonText-Bold.ttf",
            italic = "stui-LibreCaslonText-Italic.ttf", bolditalic = "stui-LibreCaslonText-Bold.ttf" },
        serif = { regular = "stui-LibreCaslonText-Italic.ttf", bold = "stui-LibreCaslonText-Bold.ttf",
            italic = "stui-LibreCaslonText-Italic.ttf", bolditalic = "stui-LibreCaslonText-Bold.ttf" },
        line = 1, frame = "page", radius = 0, shadow = "pages", shade = Blitbuffer.COLOR_GRAY_9,
        ink = Blitbuffer.COLOR_GRAY_2, paper = W, press = Blitbuffer.COLOR_GRAY_2,
        band = "rule", fill = "solid", track = "ribbon", knob = "ribbon", glyph = 0.7,
    },
}

local current

--- The theme in use (read once a session: changing it needs a restart).
function M.current()
    if not current then
        local id = "retro"
        pcall(function() id = require("bos_settings_store").get("theme") or "retro" end)
        current = M.THEMES[id] or M.THEMES.retro
        current.id = M.THEMES[id] and id or "retro"
    end
    return current
end

function M.id() return M.current().id end
function M.is(id) return M.current().id == id end

return M
