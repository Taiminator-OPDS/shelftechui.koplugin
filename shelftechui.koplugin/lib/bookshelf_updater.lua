--[[
ShelfTechUI: Bookshelf's self-updater, switched off.

Bookshelf ships inside ShelfTechUI, so updating it on its own would install
stock Bookshelf as a second plugin beside ShelfTechUI (two home screens, two
sets of settings). Every entry point the rest of Bookshelf calls is kept, and
each says that updates come with ShelfTechUI.
--]]

local Updater = {}

local function bookshelfVersion()
    local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/lib/[^/]+$") or "."
    local ok, meta = pcall(dofile, dir .. "/bookshelf_meta.lua")
    return ok and type(meta) == "table" and meta.version or "?"
end

local function explain()
    local ok, InfoMessage = pcall(require, "ui/widget/infomessage")
    if not ok then return end
    local _ = require("gettext")
    require("ui/uimanager"):show(InfoMessage:new{
        text = _("Bookshelf is part of ShelfTechUI here, so it updates with ShelfTechUI."),
    })
end

Updater._unpackStripRoot = function() return nil end
function Updater.pluginDir() return (debug.getinfo(1, "S").source or ""):match("^@(.*)/lib/[^/]+$") end
function Updater.getInstalledVersion() return bookshelfVersion() end
function Updater.otherCopies() return {} end
function Updater.composeBranchUrl() return nil end
function Updater.offerReleasesPage() explain() end
function Updater.getAvailableUpdate() return nil end
function Updater.checkBackground() end
function Updater.gateOnConnection() return false end
function Updater.check() explain() end
function Updater.install() explain() end
function Updater.installBranch() explain() end
function Updater.installLatestStable() explain() end

return Updater
