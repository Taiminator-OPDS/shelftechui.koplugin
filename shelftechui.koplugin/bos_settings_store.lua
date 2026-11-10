--[[
ShelfTechUI settings: one table in KOReader's settings ("bookshelfos").
--]]

local KEY = "bookshelfos"

local DEFAULTS = {
    -- Home
    home_status_bar = true,     -- the status bar across the top of Bookshelf home
    home_chip_labels = false,   -- names under the icons on the home chips
    home_swipe = "summary",     -- swipe down on home: "summary" | "settings" | "menu"
    summary_stats = true,       -- the reading summary: figures
    summary_books = 4,          -- … and how many recent books
    summary_badges = true,      -- … with the time spent reading each
    -- In a book
    reader_swipe = "qs",        -- swipe down in a book: "qs" | "settings" | "menu"
    qs_brightness = true,       -- Quick Settings: brightness slider
    qs_warmth = true,           -- … warmth slider
    toolbar_edges = true,
    custom_nav = true,          -- ShelfTechUI's own Contents, Notes and Go to page       -- tapping the top / bottom edge opens the reading toolbar
    stats_button = "panel",     -- STATS opens: "panel" | "koreader"
    text_sheet = true,          -- the redesigned text sheet (off: KOReader's own)
    -- KOReader's own screens in the Bookshelf look
    skin_lists = true,          -- Contents, Bookmarks, page list, search results
    skin_dictionary = true,     -- the dictionary pop-up
    skin_skim = true,           -- the skim bar
    skin_search = true,         -- the search dialogs
    skin_toasts = true,
    skin_highlight = true,      -- the highlight menu
    skin_dialogs = true,        -- system pop-ups (notices, confirmations)
    skin_menu = true,           -- KOReader's main menu
    skin_calendar = true,       -- the reading calendar         -- the small notifications
    -- (toolbar_zone, stats_view below)
    theme = "retro",            -- Settings → Themes (read at start)
    toolbar_zone = "medium",    -- tapping the middle of the page opens the reading toolbar:
                                -- "narrow" | "medium" | "wide" | "off"
    status_icons = true,        -- status lines: ShelfTechUI's icon row (false: Bookshelf's own)
    stats_view = "chapters",    -- the stats panel's last view
    map_grid = "g3",            -- the page map's grid: "g2" | "g3" | "g4"
}

local Store = {}
Store.DEFAULTS = DEFAULTS

local function tbl()
    local t = G_reader_settings:readSetting(KEY)
    if type(t) ~= "table" then
        t = {}
        G_reader_settings:saveSetting(KEY, t)
    end
    return t
end

function Store.get(key)
    local v = tbl()[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

function Store.set(key, value)
    local t = tbl()
    t[key] = value
    G_reader_settings:saveSetting(KEY, t)
end

--- The live table (for Dispatcher's sub-menus, which edit it in place).
function Store.raw() return tbl() end

function Store.save() G_reader_settings:saveSetting(KEY, tbl()) end

return Store
