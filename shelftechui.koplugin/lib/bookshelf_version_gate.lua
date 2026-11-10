-- lib/bookshelf_version_gate.lua
-- Bookshelf crashes on a KOReader older than v2025.08, which reached readers as
-- a crash with nothing to say why: the RGB32 rounded-rect and border painters
-- (koreader-base, v2025.08) are called on every colour cover's first paint and
-- on every folder and series card, and ButtonDialog:addWidget (KOReader PR
-- 13893) on several menus. This gate is for CRASHES only (maintainer): from
-- v2025.08 Bookshelf runs, and what v2026.03 adds is cosmetic (rounded corners,
-- ButtonTable backgrounds, the quote of the day's jump to its page), which is
-- no reason to turn a reader away. Keep it that way: raise M.MIN only for a
-- version that would crash.
--
-- main.lua asks this first, before any other bookshelf module loads, and on an
-- older version the plugin is a stub: one menu line saying what to do, and
-- nothing else of bookshelf's runs.
--
-- Only what every KOReader has is used here (version, WidgetContainer, the
-- main menu, InfoMessage, gettext), since this is the one file that has to
-- work on the versions the rest does not.
local M = {}

-- v2025.08 in KOReader's normalised form (Version:getNormalizedVersion):
-- yyyymm, then the point release and the commits since the tag.
M.MIN = 202508000000
M.MIN_NAME = "v2025.08"

-- tooOld() -> true only when the running KOReader's version can be read and
-- is older than M.MIN. A version that cannot be read (no git-rev, or one
-- KOReader's parser makes nothing of, which comes back as 0) is let through:
-- a custom build is not shut out on a guess.
function M.tooOld()
    local ok, v = pcall(function()
        local Version = require("version")
        return Version:getNormalizedVersion(Version:getCurrentRevision())
    end)
    v = ok and tonumber(v) or nil
    if not v or v <= 0 then return false end
    return v < M.MIN
end

local function gettext(s)
    local ok, G = pcall(require, "gettext")
    if ok and type(G) == "function" then return G(s) end
    if ok and type(G) == "table" and getmetatable(G) and getmetatable(G).__call then return G(s) end
    return s
end

-- stub(WidgetContainer) -> the plugin bookshelf is on a KOReader too old for
-- it: in the main menu once, as a line that says what to do.
function M.stub(WidgetContainer)
    local text = "Update KOReader to " .. M.MIN_NAME .. " or newer to use Bookshelf"
    local Stub = WidgetContainer:extend{
        name = "bookshelf",
        is_doc_only = false,
    }
    function Stub:init()
        if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
            self.ui.menu:registerToMainMenu(self)
        end
    end
    function Stub:addToMainMenu(menu_items)
        menu_items.bookshelf_update_koreader = {
            text = gettext(text),
            sorting_hint = "tools",
            callback = function()
                local ok_u, UIManager = pcall(require, "ui/uimanager")
                local ok_i, InfoMessage = pcall(require, "ui/widget/infomessage")
                if ok_u and ok_i then
                    UIManager:show(InfoMessage:new{ text = gettext(text) })
                end
            end,
        }
    end
    pcall(function()
        require("logger").warn("[bookshelf] KOReader is older than " .. M.MIN_NAME .. ": Bookshelf is switched off")
    end)
    return Stub
end

return M
