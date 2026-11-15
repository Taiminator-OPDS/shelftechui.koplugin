--[[
Hardcover on home: a book of yours that a reader you follow is reading (or
has read) says so on its cover.

    ┌──────────────┐
    │ 42% · Ana    │   ← reading it now, and how far
    │              │
    │   (cover)    │      "★ 5 · Tomás" when they've finished it;
    │              │      "+2" after the name when more friends have it
    └──────────────┘

The book is matched by its Hardcover link when it has one, else by its
title, against what ShelfTechUI last fetched about the readers you follow
(bos_hardcover keeps that on the device). Nothing here touches the network
or the disk while home is painting: a cover costs two table lookups, and a
book nobody has costs one.

  M.install()    once
  M.badgeFor(book) → text | nil
--]]

local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local memo, memo_gen, memo_links = {}, -1, nil

--- What a cover says about your friends and this book, or nil.
function M.badgeFor(book)
    if type(book) ~= "table" or type(book.filepath) ~= "string" or book.is_remote or book.is_folder then return nil end
    local HC = package.loaded["bos_hardcover"]
    if not HC then
        -- (loaded only once Hardcover has been used: a device that never
        -- signed in pays nothing here)
        if M.unused == nil then
            local lfs = require("libs/libkoreader-lfs")
            M.unused = lfs.attributes(require("datastorage"):getSettingsDir() .. "/stui_hardcover.lua", "mode") ~= "file"
        end
        if M.unused then return nil end
        HC = require("bos_hardcover")
    end
    if not HC.signedIn() or HC.get("home_badges", true) == false then return nil end
    local links = HC.get("links")
    if memo_gen ~= (HC.social_gen or 0) or memo_links ~= (HC.links_gen or 0) then
        memo, memo_gen, memo_links = {}, HC.social_gen or 0, HC.links_gen or 0
    end
    local hit = memo[book.filepath]
    if hit ~= nil then return hit or nil end
    local link = links and links[book.filepath]
    local also = HC.friendsWith(book.title, link and link.id)
    local text = false
    if also and #also > 0 then
        -- the one reading it now, before one who's finished it
        local e = also[1]
        for _i, a in ipairs(also) do if a.status == 2 then e = a break end end
        local name = (e.who.name or e.who.username or "?"):match("^%S+") or "?"
        if e.status == 2 then
            text = e.percent and T(_("%1% · %2"), e.percent, name) or T(_("Reading · %1"), name)
        else
            text = e.rating and T(_("★ %1 · %2"), (string.format("%.1f", e.rating):gsub("%.0$", "")), name) or T(_("Read · %1"), name)
        end
        if #also > 1 then text = text .. " +" .. (#also - 1) end
    end
    memo[book.filepath] = text
    return text or nil
end

local function paintBadge(self, bb, x, y)
    -- covers on a shelf only (not the hero's, a folder's stack, a list row)
    if not (self.show_progress and self.book) then return end
    local text = M.badgeFor(self.book)
    if not text then return end
    local Look = require("bos_look")
    local S = Look.S
    local card_w = self.width
    if self._cardDimensions then card_w = (self:_cardDimensions()) end
    local h = math.max(S(15), math.floor(card_w * 0.13))
    bb:paintRect(x, y, card_w, h, Blitbuffer.COLOR_BLACK)
    Look.label(bb, text, x + S(3), y, card_w - S(6), h, math.max(7, math.min(9, math.floor(card_w / 14))),
        { align = "center", color = Blitbuffer.COLOR_WHITE, keep_case = true })
end

function M.install()
    local ok, SW = pcall(require, "lib/bookshelf_spine_widget")
    if not ok or type(SW) ~= "table" or SW._stui_friends then return end
    SW._stui_friends = true
    local orig = SW.paintTo
    SW.paintTo = function(self, bb, x, y)
        orig(self, bb, x, y)
        local okP, err = pcall(paintBadge, self, bb, x, y)
        if not okP then logger.warn("ShelfTechUI: friends badge:", err) end
    end
end

return M
