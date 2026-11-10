--[[--
Fonts: Bookshelf's UI font (Bookshelf menu → Fonts), so every ShelfTechUI
surface matches the shelf; KOReader's UI font without Bookshelf. The faces live
in bos_ui; this module keeps the toolbar's short names.
--]]

local UI = require("bos_ui")

local M = {
    face = UI.face,
    boldFace = UI.boldFace,
    italicFace = UI.italicFace,
    caps = UI.caps,
}

--- Is Bookshelf installed (its modules can be loaded)?
function M.hasBookshelf()
    local ok, BF = pcall(require, "lib/bookshelf_fonts")
    return ok and type(BF) == "table" and type(BF.getFace) == "function"
end

return M
