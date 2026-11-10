-- lib/bookshelf_storage_move.lua
-- One-time move from the old flat layout (bookshelf_*.lua and friends loose
-- in settings/) into the two folders lib/bookshelf_paths describes. Runs
-- first thing in main.lua, before any store opens its file: KOReader
-- rewrites a settings file it holds open, so a file must never move under
-- an open handle.
--
-- A move is a rename, so a database's -wal and -shm companions go with it
-- and nothing is copied. A file already at the new place wins, and the old
-- one is left where it is, untouched (an older bookshelf run again after
-- the move writes the old names afresh; neither copy is lost). Nothing is
-- ever deleted here.
local logger = require("logger")

local M = {}

-- Seams (tests replace these).
M._fs = nil
local function fs()
    if M._fs then return M._fs end
    local lfs = require("libs/libkoreader-lfs")
    return {
        exists = function(p) return lfs.attributes(p, "mode") ~= nil end,
        isDir = function(p) return lfs.attributes(p, "mode") == "directory" end,
        mkdir = function(p) return require("lib/bookshelf_fs").ensureDir(p) end,
        rename = os.rename,
        -- lfs.dir returns two values; the loop must see both.
        list = function(p)
            local out = {}
            pcall(function()
                for n in lfs.dir(p) do
                    if n ~= "." and n ~= ".." then out[#out + 1] = n end
                end
            end)
            return out
        end,
        rmdir = function(p) return lfs.rmdir(p) end,
    }
end

-- old name under settings/ -> { "settings" | "cache", new name }
local FILES = {
    { "bookshelf.lua",                  "settings", "settings.lua" },
    { "bookshelf_micromodules.lua",     "settings", "micromodule_data.lua" },
    { "bookshelf_hardcover_links.lua",  "settings", "hardcover_links.lua" },
    { "bookshelf_book_facts.sqlite3",   "settings", "book_facts.sqlite3" },
    { "bookshelf_hardcover.sqlite3",    "settings", "hardcover.sqlite3" },
    { "bookshelf_opds.sqlite3",         "cache",    "opds.sqlite3" },
    { "bookshelf_opds.lua",             "cache",    "opds.lua" },
    { "bookshelf_changelog.lua",        "cache",    "changelog.lua" },
    { "bookshelf_hero_inflight",        "cache",    "hero_inflight" },
    { "bookshelf_covers",               "cache",    "covers" },
    { "bookshelf_hardcover",            "cache",    "hardcover" },
    { "bookshelf_cache",                "cache",    "updater" },
}
-- Companions that travel with a file: LuaSettings' backup, SQLite's WAL.
local COMPANIONS = { "", ".old", "-wal", "-shm", "-journal" }

function M.run()
    local ok, err = pcall(function()
        local Paths = require("lib/bookshelf_paths")
        local F = fs()
        local sdir, cdir = Paths.settingsDir(), Paths.cacheDir()
        F.mkdir(sdir); F.mkdir(cdir)
        local base = require("datastorage"):getSettingsDir()
        local moved = 0
        local function move(from, to)
            if not F.exists(from) then return end
            if F.exists(to) then
                logger.warn("[bookshelf] storage: kept", to, "and left", from, "where it is")
                return
            end
            local ok_r, why = F.rename(from, to)
            if ok_r then moved = moved + 1
            else logger.warn("[bookshelf] storage: could not move", from, "->", to, tostring(why)) end
        end
        for _i, f in ipairs(FILES) do
            local dest = (f[2] == "settings") and sdir or cdir
            for _j, c in ipairs(COMPANIONS) do
                move(base .. "/" .. f[1] .. c, dest .. "/" .. f[3] .. c)
            end
        end
        -- The scaled-cover cache was already under cache/, at its root.
        move(require("datastorage"):getDataDir() .. "/cache/bookshelf_covers", cdir .. "/scaled_covers")
        -- Ornaments, from the folder they lived in before 5.3 (every 5.2
        -- reader's) into settings/bookshelf/ornaments, entry by entry: the
        -- new folder may already exist. A piece is named by its path inside
        -- the folder, so the deck, switched-off pieces and packs carry over.
        -- Hidden entries (a sync tool's markers) stay; the old folder goes
        -- only once it is empty, and is still read for whatever stayed.
        local old_orn = require("datastorage"):getDataDir() .. "/icons/bookshelf.ornaments"
        if F.isDir(old_orn) then
            local new_orn = sdir .. "/ornaments"
            F.mkdir(new_orn)
            for _i, name in ipairs(F.list(old_orn)) do
                if name:sub(1, 1) ~= "." then move(old_orn .. "/" .. name, new_orn .. "/" .. name) end
            end
            if #F.list(old_orn) == 0 then F.rmdir(old_orn) end
        end
        if moved > 0 then logger.info("[bookshelf] storage: moved", moved, "item(s) into", sdir, "and", cdir) end
    end)
    if not ok then logger.warn("[bookshelf] storage move failed:", tostring(err)) end
end

return M
