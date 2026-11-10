--[[
Choose a folder, in ShelfTechUI's look: tap a folder to go into it, ‹ UP to go
back out, USE THIS FOLDER to pick the one you're in. (KOReader's own chooser
needs a long-press to pick, which nobody finds.)

    require("bos_folders").choose(start_path, function(path) ... end, title)
--]]

local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local T = require("ffi/util").template

local Look = require("bos_look")
local S = Look.S

local M = {}

local function subfolders(path)
    local out = {}
    local ok = pcall(function()
        for name in lfs.dir(path) do
            -- (not hidden folders, nor KOReader's own .sdr book folders)
            if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local full = (path == "/" and "" or path) .. "/" .. name
                if lfs.attributes(full, "mode") == "directory" then table.insert(out, name) end
            end
        end
    end)
    if not ok then return {} end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

local function parent(path)
    if path == "/" then return nil end
    local p = path:match("^(.*)/[^/]+$")
    if p == nil or p == "" then return "/" end
    return p
end

function M.choose(start, done, title)
    local Page = require("bos_page")
    local path = start
    if not path or lfs.attributes(path, "mode") ~= "directory" then
        path = G_reader_settings:readSetting("home_dir") or "/"
    end
    local list, page_no = subfolders(path), 1

    local function go(p)
        path, list, page_no = p, subfolders(p), 1
    end

    local function draw(self, bb, y, w)
        local x = self.pad
        local H = require("device").screen:getHeight()
        -- where you are
        Look.label(bb, _("Folder"), x, y, w, S(18), 10, { color = Look.GRAY })
        y = y + S(20)
        y = y + Page.wrap(bb, path, Page.serif(17, true), x, y, w, 2, S(24)) + S(10)
        -- [‹ UP]                          [USE THIS FOLDER]
        local bh = S(42)
        local up = parent(path)
        local uw = S(110)
        local r = Look.button(bb, x, y, uw, bh, "\u{2039} " .. _("Up"), { size = 13, enabled = up ~= nil })
        if up then self:hit(r, function(p) go(up) p:refresh("ui") end) end
        local usew = math.min(w - uw - S(20), S(240))
        r = Look.button(bb, x + w - usew - Look.SHADOW_SMALL, y, usew, bh, _("Use this folder"), { size = 13, on = true })
        self:hit(r, function(p)
            local chosen = path
            p:onClose()
            done(chosen)
        end)
        y = y + bh + Look.SHADOW_SMALL + S(16)
        Page.heading(bb, T(_("%1 folders inside"), #list), x, y, w)
        y = y + S(30)
        -- the folders, a page at a time
        local rh = S(50)
        local footer = S(56)
        local per = math.max(1, math.floor((H - y - footer) / rh))
        local pages = math.max(1, math.ceil(#list / per))
        page_no = math.max(1, math.min(page_no, pages))
        if #list == 0 then
            Page.wrap(bb, _("No folders in here."), Page.serif(16, false, true), x, y + S(8), w, 2, S(24), Look.GRAY)
        end
        for i = (page_no - 1) * per + 1, math.min(#list, page_no * per) do
            local name = list[i]
            Look.label(bb, name, x + S(8), y, w - S(40), rh, 15, { keep_case = true, bold = false })
            Look.label(bb, "\u{203A}", x + w - S(30), y, S(24), rh, 16, { align = "center" })
            bb:paintRect(x, y + rh - 1, w, 1, Look.LIGHT)
            local target = (path == "/" and "" or path) .. "/" .. name
            self:hit(Geom:new{ x = x, y = y, w = w, h = rh }, function(p) go(target) p:refresh("ui") end)
            y = y + rh
        end
        if pages > 1 then
            local fy = H - footer + S(8)
            local bw = S(60)
            r = Look.button(bb, x, fy, bw, S(38), "\u{2039}", { size = 16, enabled = page_no > 1 })
            if page_no > 1 then self:hit(r, function(p) page_no = page_no - 1 p:refresh("ui") end) end
            Look.label(bb, T("%1 / %2", page_no, pages), x, fy, w, S(38), 13, { align = "center" })
            r = Look.button(bb, x + w - bw - Look.SHADOW_SMALL, fy, bw, S(38), "\u{203A}", { size = 16, enabled = page_no < pages })
            if page_no < pages then self:hit(r, function(p) page_no = page_no + 1 p:refresh("ui") end) end
        end
    end

    Page:new{ caption = title or _("Choose a folder"), draw = draw,
        on_swipe = function(self, dir)
            if dir == "west" then page_no = page_no + 1 self:refresh("ui")
            elseif dir == "east" then
                if page_no > 1 then page_no = page_no - 1 self:refresh("ui") else self:onClose() end
            end
        end }:show()
end

return M
