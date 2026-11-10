--[[
ShelfTechUI's Settings app in Bookshelf's start menu (≡).

Bookshelf's start menu runs Dispatcher actions, and ShelfTechUI registers
one for its Settings app ("bookshelfos_settings"), so the app can sit in any
menu that takes actions: the start menu, gestures, profiles, the home status
bar and Quick Settings.

This module puts it in the start menu for you: once, at the top, the first
time ShelfTechUI runs with Bookshelf installed, and on or off from
Settings → ShelfTechUI → Home → "Settings in the start menu". It finds the
entry by its action, so a copy you added yourself (or moved, or renamed)
counts too.
--]]

local logger = require("logger")
local _ = require("gettext")

local M = {}

M.ID = "sm_bookshelfos_settings"
local ACTION = "bookshelfos_settings"
local ICON = "\xEF\x80\x93" -- U+F013 fa-cog (Private Use Area, as Bookshelf asks)
local SEEDED = "startmenu_seeded"

local function model()
    local ok, Model = pcall(require, "lib/bookshelf_start_menu_model")
    if ok and type(Model) == "table" and Model.load and Model.save then return Model end
end

function M.available() return model() ~= nil end

local function isOurs(it)
    return type(it) == "table" and (it.id == M.ID
        or (it.type == "action" and type(it.action) == "table" and it.action[ACTION]))
end

--- Is the Settings app in the start menu (at the top level or in a folder)?
function M.has()
    local Model = model()
    if not Model then return false end
    local ok, items = pcall(Model.load)
    if not ok or type(items) ~= "table" then return false end
    for _i, it in ipairs(items) do
        if isOurs(it) then return true end
        if it.type == "folder" then
            for _j, c in ipairs(it.children or {}) do if isOurs(c) then return true end end
        end
    end
    return false
end

--- Put it at the top of the start menu.
function M.add()
    local Model = model()
    if not Model or M.has() then return false end
    local ok, err = pcall(function()
        local items = Model.load()
        table.insert(items, 1, { id = M.ID, type = "action", label = _("Settings"), icon = ICON,
            action = { [ACTION] = true } })
        Model.save(items)
    end)
    if not ok then logger.warn("ShelfTechUI: start menu:", err) return false end
    return true
end

--- Take it out (wherever it is).
function M.remove()
    local Model = model()
    if not Model then return false end
    local ok, err = pcall(function()
        local items = Model.load()
        local out = {}
        for _i, it in ipairs(items) do
            if not isOurs(it) then
                if it.type == "folder" then
                    local kids = {}
                    for _j, c in ipairs(it.children or {}) do if not isOurs(c) then kids[#kids + 1] = c end end
                    local copy = {}
                    for k, v in pairs(it) do copy[k] = v end
                    copy.children = kids
                    it = copy
                end
                out[#out + 1] = it
            end
        end
        Model.save(out)
    end)
    if not ok then logger.warn("ShelfTechUI: start menu:", err) return false end
    return true
end

function M.set(on)
    if on then return M.add() end
    return M.remove()
end

--- The first time ShelfTechUI runs with Bookshelf: put it in, once.
function M.seed()
    if not M.available() then return end
    local Store = require("bos_settings_store")
    if Store.get(SEEDED) then return end
    Store.set(SEEDED, true)
    M.add()
end

return M
