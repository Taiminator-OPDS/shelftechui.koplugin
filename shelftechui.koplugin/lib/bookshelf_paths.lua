-- lib/bookshelf_paths.lua
-- Where bookshelf keeps its files, in two folders (maintainer: "back up that
-- folder to back up bookshelf"):
--
--   settings/bookshelf/  the reader's own: preferences, micro-module data,
--                        Hardcover links and cache, page counts; and their
--                        content folders (wallpapers, ornaments, quotes,
--                        micro-modules). This is the folder to back up.
--   cache/bookshelf/     what rebuilds itself: cover caches, the OPDS feed
--                        cache, updater downloads, cached release notes.
--
-- Not ours, and left where they are: KOReader's own files (history,
-- collections, book sidecars, settings.reader.lua), other plugins' settings,
-- and the fonts KOReader needs in its fonts folder. The three status-line
-- settings that were in settings.reader.lua are now in our settings file
-- (lib/bookshelf_settings_store moves them).
--
-- The folders are made on first use; lib/bookshelf_storage_move brings files
-- over from the old flat layout.
local M = {}

local function ds() return require("datastorage") end

function M.settingsDir() return ds():getSettingsDir() .. "/bookshelf" end
function M.cacheDir() return ds():getDataDir() .. "/cache/bookshelf" end

local _made = {}
local function ensure(dir)
    if _made[dir] then return end
    local ok, fs = pcall(require, "lib/bookshelf_fs")
    if ok and fs and fs.ensureDir and fs.ensureDir(dir) then _made[dir] = true end
end

-- settingsFile(name) / cacheFile(name) -> the path of `name` in that folder,
-- which is made if it is not there yet.
function M.settingsFile(name)
    local d = M.settingsDir(); ensure(d)
    return d .. "/" .. name
end
function M.cacheFile(name)
    local d = M.cacheDir(); ensure(d)
    return d .. "/" .. name
end

return M
