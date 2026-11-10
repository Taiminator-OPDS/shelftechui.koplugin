--[[
Bookshelf's theme packs (wallpapers, plank designs, ornaments, colour packs)
were removed in ShelfTechUI 1.3.1: ShelfTechUI's own themes (Settings →
Themes) style the whole interface instead. This stand-in keeps the one seam
the shelf still reads through: every part of the old look answers "default",
and anything else is the reader's own setting, as before.
--]]
local M = {}

M.SHELF_SETTING = "shelf_theme"
M.PLANK_SETTING = "theme_plank_pack"

local function store()
    local ok, S = pcall(require, "lib/bookshelf_settings_store")
    return ok and S or nil
end
local function read(k) local s = store() return s and s.read(k) end
local function save(k, v)
    local s = store(); if not s then return end
    s.save(k, v); if s.flush then pcall(s.flush) end
end

-- The parts of the old look: colour keys (both slots), wallpaper, panel and
-- plank keys. Stored values from before 1.3.1 are ignored: the defaults paint.
local COLOURS = { "ink_color", "progress_fill", "progress_track", "bookmark_color",
    "complete_bookmark_color", "favorite_star_color", "favorite_heart_color", "badge_fg",
    "badge_bg", "chrome_bg", "module_bg", "module_border", "panel_color", "panel_ink",
    "border_color", "selection_color", "card_shadow_color", "spine_plank_color",
    "folder_overlay_bg", "folder_overlay_fg", "chip_selected_bg", "chip_selected_fg",
    "wallpaper_bg" }
M.PART_KEYS = {
    shelf_theme = true, wallpaper_default = true, wallpaper_full = true,
    wallpaper_invert_night = true, theme_plank_pack = true, chip_bar_transparent = true,
    wallpaper_chrome_scrim = true, wallpaper_transparent_buttons = true,
    wallpaper_panel_blur = true, covers_full_panel = true,
}
for _i, k in ipairs(COLOURS) do M.PART_KEYS[k] = true; M.PART_KEYS[k .. "_night"] = true end
function M.isPart(key) return M.PART_KEYS[key] == true end

function M.partRead(key)
    if M.isPart(key) then return nil end
    return read(key)
end
function M.partSave(key, v) if not M.isPart(key) then save(key, v) end end
function M.partDelete(key) M.partSave(key, nil) end
function M.partSnapshot(key) return { v = M.partRead(key) } end
function M.partRestore(key, snap) M.partSave(key, snap and snap.v) end
function M.partClear() end

function M.colour() return nil end
function M.shelfLook() return "auto" end
function M.shelfKey() return "lib" end
function M.setShelf() return false end
function M.anyShelfTheme() return false end
function M.ornamentsFor() return "plain" end
function M.shownWallpaper() return nil end
function M.wallpaperPath() return nil end
function M.isDarkName() return false end
function M.activePlank() return nil end
function M.plankForChoice() return nil end

return M
