--[[
Updates, from the plugin's GitHub releases (github.com/Taiminator-OPDS/
shelftechui.koplugin). Settings → System → Updates.

  check(opts)       ask GitHub for the newest release (a background process,
                    so nothing waits); opts.manual says "up to date" too
  autoCheck()       once a day on Wi-Fi, when "Check automatically" is on
  install(rel)      download, verify and unpack in a background process,
                    then swap folders and restart KOReader
  rollback()        the previous version back (kept beside the plugin)

Nothing changes until the new version is complete and checked: the zip is
downloaded to a temporary file, its size (and SHA-256, when GitHub gives one
and the device has sha256sum) must match the release, it unpacks into a
hidden folder next to the plugin, and that folder must hold ShelfTechUI at
the version being installed. Only then is the running folder renamed to
.stui-previous and the new one put in its place, and KOReader restarts at once
(the old code is still loaded until it does).
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Store = require("bos_settings_store")

local M = {}

M.OWNER, M.REPO = "Taiminator-OPDS", "shelftechui.koplugin"
M.ASSET = "shelftechui.koplugin.zip"
M.PREVIOUS = ".stui-previous"
M.STAGING = ".stui-update"

-- ---------------------------------------------------------------- where things are

--- The running plugin's folder (no trailing slash), its parent, its name.
function M.paths()
    local dir = require("bos_ui").PLUGIN_DIR:gsub("/+$", "")
    local parent, name = dir:match("^(.*)/([^/]+)$")
    return dir, parent or ".", name or "shelftechui.koplugin"
end

local function cacheDir()
    local d = require("datastorage"):getDataDir() .. "/cache/stui_update"
    if lfs.attributes(d, "mode") ~= "directory" then
        lfs.mkdir(require("datastorage"):getDataDir() .. "/cache")
        lfs.mkdir(d)
    end
    return d
end

local function readMeta(dir)
    local ok, meta = pcall(function()
        -- _meta.lua calls gettext; dofile runs it as-is
        return dofile(dir .. "/_meta.lua")
    end)
    if ok and type(meta) == "table" then return meta end
end

function M.installed()
    local dir = M.paths()
    local meta = readMeta(dir)
    return meta and meta.version or "0"
end

--- The version kept from before the last update, or nil.
function M.previous()
    local _dir, parent = M.paths()
    local meta = readMeta(parent .. "/" .. M.PREVIOUS)
    return meta and meta.name == "shelftechui" and meta.version or nil
end

-- ---------------------------------------------------------------- versions

--- "1.4.2" / "v1.5.0-beta.2" -> { 1, 4, 2 }, pre ("beta.2" or nil)
local function parse(v)
    v = tostring(v or ""):gsub("^[vV]", "")
    local core, pre = v:match("^([%d%.]+)%-?(.*)$")
    local nums = {}
    for n in (core or ""):gmatch("%d+") do table.insert(nums, tonumber(n)) end
    return nums, (pre ~= "" and pre or nil)
end

--- a newer than b?
function M.newer(a, b)
    local na, pa = parse(a)
    local nb, pb = parse(b)
    for i = 1, math.max(#na, #nb) do
        local x, y = na[i] or 0, nb[i] or 0
        if x ~= y then return x > y end
    end
    -- same numbers: a release is newer than its pre-releases
    if pa and not pb then return false end
    if pb and not pa then return true end
    if pa and pb then
        local xa, xb = tonumber(pa:match("(%d+)$")) or 0, tonumber(pb:match("(%d+)$")) or 0
        if pa:gsub("%d+$", "") == pb:gsub("%d+$", "") then return xa > xb end
        return pa > pb
    end
    return false
end

-- ---------------------------------------------------------------- the check

local function wifiOn()
    local ok, on = pcall(function()
        local NM = require("ui/network/manager")
        return NM:isWifiOn() and NM:isConnected()
    end)
    return ok and on
end

local function resultFile() return cacheDir() .. "/latest.lua" end

--- In the child: GitHub's releases, the newest one we'd install, saved.
local function fetchLatest(beta)
    local Http = require("lib/bookshelf_http")
    local base = "https://api.github.com/repos/" .. M.OWNER .. "/" .. M.REPO
    local list
    if beta then
        list = Http.getJSON(base .. "/releases?per_page=10", { accept = "application/vnd.github+json",
            user_agent = "KOReader-ShelfTechUI" })
    else
        local one = Http.getJSON(base .. "/releases/latest", { accept = "application/vnd.github+json",
            user_agent = "KOReader-ShelfTechUI" })
        list = one and { one } or nil
    end
    local raw_list = list
    -- (an error comes back as a table too: { message = ... })
    if type(list) == "table" and list.message and not list[1] then list = nil end
    if list and list[1] and type(list[1]) == "table" and list[1].message and not list[1].tag_name then list = nil end
    local out = { at = os.time(), ok = list ~= nil }
    -- why not, in GitHub's words when it gave any (shown in Settings)
    if not out.ok then
        local why
        if type(raw_list) == "table" then
            why = raw_list.message or (type(raw_list[1]) == "table" and raw_list[1].message)
        end
        out.error = why and tostring(why):sub(1, 160) or "no answer"
    end
    local best
    for _i, r in ipairs(list or {}) do
        if type(r) == "table" and not r.draft and (beta or not r.prerelease) and r.tag_name then
            local asset
            for _j, a in ipairs(r.assets or {}) do
                if a.name == M.ASSET then asset = a break end
                if not asset and type(a.name) == "string" and a.name:match("%.zip$") then asset = a end
            end
            if asset and (not best or M.newer(r.tag_name, best.tag)) then
                best = {
                    tag = r.tag_name, version = tostring(r.tag_name):gsub("^[vV]", ""),
                    notes = r.body or "", prerelease = r.prerelease and true or false,
                    url = asset.browser_download_url, size = tonumber(asset.size),
                    digest = type(asset.digest) == "string" and asset.digest:match("^sha256:(%x+)$") or nil,
                }
            end
        end
    end
    out.release = best
    local LuaSettings = require("luasettings")
    local s = LuaSettings:open(resultFile())
    s:saveSetting("result", out)
    s:flush()
end

local function readResult()
    local ok, s = pcall(function() return require("luasettings"):open(resultFile()) end)
    return ok and s and s:readSetting("result") or nil
end

--- What GitHub said last (nil if never asked).
function M.latest() return readResult() end

--- An update newer than what's installed, from the last check, or nil.
function M.available()
    local r = readResult()
    local rel = r and r.release
    if rel and M.newer(rel.version, M.installed()) then return rel end
end

local function cleanNotes(s)
    s = tostring(s or ""):gsub("\r", "")
    s = s:gsub("%*%*", ""):gsub("`", ""):gsub("\n%s*%- ", "\n• "):gsub("^%s*%- ", "• ")
    s = s:gsub("\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    if #s > 700 then s = s:sub(1, 700):gsub("[^\n]*$", "") .. "…" end
    return s
end

--- Offer `rel`: what's new, then Update.
-- The offer: a window of our own, sized to the screen. (It was KOReader's
-- ConfirmBox, which grows with its text: a release with long notes made it
-- taller than the screen, so its frame was drawn over itself and its keys
-- fell off the bottom.) What's new is shown a page at a time, and the two
-- keys are always inside the window.
local Offer

local function offerClass()
    if Offer then return Offer end
    local Blitbuffer = require("ffi/blitbuffer")
    local Device = require("device")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Look = require("bos_look")
    local UI = require("bos_ui")
    local Page = require("bos_page")
    local Screen = Device.screen
    local S = Look.S
    local function inside(p, r) return p and r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end
    local function tface(size, bold)
        return Look.text(size, bold) or (bold and UI.boldFace(size)) or UI.face(size)
    end

    Offer = InputContainer:extend{ name = "stui_update_offer", rel = nil, page = 1 }

    function Offer:init()
        local W, H = Screen:getWidth(), Screen:getHeight()
        self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
        local cw = W - 2 * S(36)
        local ch = math.min(H - 2 * S(60), S(560))
        self.card = Geom:new{ x = S(36), y = math.floor((H - ch) / 2) - S(10), w = cw, h = ch }
        -- what's new, as paragraphs (one per point of the notes)
        self.paras = {}
        local notes = tostring(self.rel.notes or ""):gsub("\r", "")
        notes = notes:gsub("%*%*", ""):gsub("`", "")
        for line in (notes .. "\n"):gmatch("(.-)\n") do
            local t = line:gsub("^%s*[%-%*]%s+", "\u{2022} "):gsub("^%s+", ""):gsub("%s+$", "")
            if t ~= "" then
                if line:match("^%s%s+%S") and #self.paras > 0 and not line:match("^%s*[%-%*]%s") then
                    self.paras[#self.paras] = self.paras[#self.paras] .. " " .. t
                else
                    table.insert(self.paras, t)
                end
            end
        end
        self.face = Look.serif(15)
        self.line_h = S(22)
        -- as tall as what it says, up to most of the screen (then the notes
        -- are paged): short notes make a small window
        local w = cw - S(44)
        local title_h = Page.wrap(nil, T(_("ShelfTechUI %1 is available"), self.rel.version), tface(19, true), 0, 0, w, 2, S(28))
        local fixed = S(34) + S(16) + title_h + S(32) + S(13) + S(12) + S(12) + S(50) + S(18) + Look.SHADOW_SMALL
        local notes_h = 0
        for _i, p in ipairs(self.paras) do notes_h = notes_h + Page.wrap(nil, p, self.face, 0, 0, w, 40, self.line_h) + S(6) end
        local tallest = math.min(H - 2 * S(70), S(540))
        ch = math.max(S(240), math.min(tallest, fixed + notes_h + S(4)))
        self.card = Geom:new{ x = S(36), y = math.max(S(40), math.floor((H - ch) / 2) - S(10)), w = cw, h = ch }
        local all = function() return self.dimen end
        self.ges_events = {
            OTap = { GestureRange:new{ ges = "tap", range = all } },
            OSwipe = { GestureRange:new{ ges = "swipe", range = all } },
        }
        if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    end

    function Offer:region()
        local c = self.card
        return Geom:new{ x = c.x, y = c.y, w = c.w + S(10), h = c.h + S(10) }
    end

    --- Split the paragraphs into pages that fit `room` (a paragraph taller
    --- than a page is cut to it, with an ellipsis).
    function Offer:layout(w, room)
        if self.pages_list and self.laid_w == w and self.laid_room == room then return end
        local pages, cur, used = {}, {}, 0
        local max_lines = math.max(2, math.floor(room / self.line_h))
        for _i, p in ipairs(self.paras) do
            local h = Page.wrap(nil, p, self.face, 0, 0, w, max_lines, self.line_h)
            if used + h > room and #cur > 0 then
                pages[#pages + 1] = cur
                cur, used = {}, 0
            end
            cur[#cur + 1] = p
            used = used + h + S(6)
        end
        if #cur > 0 then pages[#pages + 1] = cur end
        if #pages == 0 then pages[1] = {} end
        self.pages_list, self.laid_w, self.laid_room = pages, w, room
        self.pages = #pages
        self.max_lines = max_lines
    end

    function Offer:paintTo(bb)
        local c = self.card
        self.hits = {}
        Look.box(bb, c.x, c.y, c.w, c.h, { shadow = S(8) })
        -- the title band
        local bh = S(34)
        Look.stripes(bb, c.x + Look.LINE, c.y + Look.LINE + S(6), c.w - 2 * Look.LINE, bh - S(12))
        local cap = _("Update")
        local tw = Look.textWidth(Look.case(cap), 12) + S(20)
        bb:paintRect(c.x + math.floor((c.w - tw) / 2), c.y + Look.LINE + S(4), tw, bh - S(8), Look.PAPER)
        Look.label(bb, cap, c.x, c.y + Look.LINE + S(2), c.w, bh - S(4), 12, { align = "center" })
        bb:paintRect(c.x, c.y + bh, c.w, Look.LINE, Look.INK)
        local x, w = c.x + S(22), c.w - S(44)
        local y = c.y + bh + S(16)
        -- what it is
        y = y + Page.wrap(bb, T(_("ShelfTechUI %1 is available"), self.rel.version), tface(19, true), x, y, w, 2, S(28))
        local sub = T(_("You have %1"), M.installed())
        if self.rel.size then sub = sub .. " \u{00B7} " .. string.format("%.1f MB", self.rel.size / 1048576) end
        Look.label(bb, sub, x, y + S(2), w, S(22), 10, { color = Look.GRAY })
        y = y + S(32)
        bb:paintRect(x, y, w, math.max(1, S(1)), Look.INK)
        y = y + S(12)
        -- the keys, always at the foot of the window
        local kh = S(50)
        local ky = c.y + c.h - kh - S(18) - Look.SHADOW_SMALL
        local gap = S(14)
        local lw = math.floor((w - gap) * 0.42)
        local r1 = Look.button(bb, x, ky, lw, kh, _("Not now"), { size = 13 })
        local r2 = Look.button(bb, x + lw + gap, ky, w - lw - gap - Look.SHADOW_SMALL, kh, _("Update and restart"), { size = 13, on = true })
        table.insert(self.hits, { id = "later", rect = r1, fn = function() UIManager:close(self) end })
        table.insert(self.hits, { id = "update", rect = r2, fn = function()
            local rel = self.rel
            UIManager:close(self)
            M.install(rel)
        end })
        -- what's new, a page at a time, between the two
        local pager_h = S(34)
        local room = ky - y - S(12)
        self:layout(w, room - pager_h)
        if self.pages <= 1 then self:layout(w, room) end
        if self.pages > 1 then room = room - pager_h end
        self.page = math.max(1, math.min(self.page, self.pages))
        local py = y
        for _i, p in ipairs(self.pages_list[self.page] or {}) do
            local left = math.floor((y + room - py) / self.line_h)
            if left < 1 then break end
            py = py + Page.wrap(bb, p, self.face, x, py, w, math.min(left, self.max_lines), self.line_h) + S(6)
        end
        if self.pages > 1 then
            local fy = ky - S(12) - pager_h + S(2)
            local kw = S(52)
            local rp = Look.button(bb, x, fy, kw, pager_h - S(6), "\u{2039}", { size = 14, enabled = self.page > 1 })
            local rn = Look.button(bb, x + w - kw - Look.SHADOW_SMALL, fy, kw, pager_h - S(6), "\u{203A}", { size = 14, enabled = self.page < self.pages })
            table.insert(self.hits, { id = "prev", rect = Geom:new{ x = rp.x - S(6), y = rp.y - S(6), w = rp.w + S(12), h = rp.h + S(12) }, fn = function() self:turn(-1) end })
            table.insert(self.hits, { id = "next", rect = Geom:new{ x = rn.x - S(6), y = rn.y - S(6), w = rn.w + S(12), h = rn.h + S(12) }, fn = function() self:turn(1) end })
            Look.label(bb, T(_("What's new \u{00B7} %1 / %2"), self.page, self.pages), x + kw, fy, w - 2 * kw, pager_h - S(6), 10, { align = "center" })
        end
    end

    function Offer:turn(d)
        local want = math.max(1, math.min(self.pages or 1, self.page + d))
        if want ~= self.page then
            self.page = want
            UIManager:setDirty(self, function() return "ui", self:region() end)
        end
    end

    function Offer:onOTap(_, ges)
        for _i, h in ipairs(self.hits or {}) do
            if inside(ges.pos, h.rect) then
                UI.press(h.rect, h.fn, function(r)
                    if UIManager:isWidgetShown(self) then UIManager:setDirty(self, function() return "ui", r end) end
                end)
                return true
            end
        end
        -- (a tap outside doesn't dismiss it: only its keys do)
        return true
    end

    function Offer:onOSwipe(_, ges)
        if ges.direction == "west" or ges.direction == "north" then self:turn(1)
        elseif ges.direction == "east" or ges.direction == "south" then self:turn(-1) end
        return true
    end

    function Offer:onClose() UIManager:close(self) return true end
    function Offer:onShow() UIManager:setDirty(self, function() return "ui", self:region() end) return true end
    function Offer:onCloseWidget()
        local r = self:region()
        UIManager:setDirty(nil, function() return "ui", r end)
    end
    return Offer
end

function M.offer(rel)
    if not rel then return end
    local ok, err = pcall(function() UIManager:show(offerClass():new{ rel = rel }) end)
    if ok then return end
    -- (our window couldn't be made: KOReader's, with short notes so it fits)
    logger.warn("ShelfTechUI: update window:", err)
    local size = rel.size and string.format(" (%.1f MB)", rel.size / 1048576) or ""
    local notes = cleanNotes(rel.notes)
    if #notes > 240 then notes = notes:sub(1, 240):gsub("[^\n]*$", "") .. "\u{2026}" end
    UIManager:show(ConfirmBox:new{
        text = T(_("ShelfTechUI %1 is available. You have %2."), rel.version, M.installed())
            .. "\n\n" .. notes .. "\n\n" .. T(_("Download it%1 and restart KOReader?"), size),
        ok_text = _("Update"),
        cancel_text = _("Not now"),
        ok_callback = function() M.install(rel) end,
    })
end

M._checking = false

--- Ask GitHub, in a background process. opts.manual: say so when there's
--- nothing new, and offer what there is; otherwise only a new version (once)
--- is offered, and only on home.
function M.check(opts)
    opts = opts or {}
    if M._checking then return end
    if not wifiOn() then
        if opts.manual then
            local NM = require("ui/network/manager")
            NM:runWhenOnline(function() M.check(opts) end)
        end
        return
    end
    local beta = Store.get("update_beta") == true
    local ffiutil = require("ffi/util")
    local ok, pid = pcall(ffiutil.runInSubProcess, function()
        local okF, err = pcall(fetchLatest, beta)
        if not okF then logger.warn("ShelfTechUI: update check failed:", err) end
    end)
    if not ok or not pid then
        logger.warn("ShelfTechUI: update check not started:", pid)
        return
    end
    M._checking = true
    Store.set("update_last_check", os.time())
    local msg
    if opts.manual then
        msg = InfoMessage:new{ text = _("Checking for updates…") }
        UIManager:show(msg)
    end
    local waited = 0
    local function poll()
        if not ffiutil.isSubProcessDone(pid) and waited < 30 then
            waited = waited + 1
            UIManager:scheduleIn(1, poll)
            return
        end
        M._checking = false
        if msg then UIManager:close(msg) end
        local r = readResult()
        local rel = M.available()
        if opts.manual then
            if rel then
                M.offer(rel)
            elseif not (r and r.ok and r.at and os.time() - r.at < 120) then
                local why = r and r.at and os.time() - r.at < 120 and r.error
                UIManager:show(InfoMessage:new{ text = _("Couldn't reach GitHub. Check the Wi-Fi and try again.")
                    .. (why and why ~= "no answer" and ("\n\n" .. T(_("GitHub said: %1"), why)) or ""), timeout = 6 })
            else
                UIManager:show(InfoMessage:new{ text = T(_("ShelfTechUI %1 is the newest version."), M.installed()), timeout = 3 })
            end
            return
        end
        if rel and Store.get("update_seen") ~= rel.version then
            -- on home, not over a book you're reading
            local ReaderUI = package.loaded["apps/reader/readerui"]
            if not (ReaderUI and ReaderUI.instance) then
                Store.set("update_seen", rel.version)
                M.offer(rel)
            end
        end
    end
    UIManager:scheduleIn(1, poll)
end

--- Once a day, on Wi-Fi, when it's on (the default).
function M.autoCheck()
    if Store.get("update_auto") == false then return end
    local last = tonumber(Store.get("update_last_check")) or 0
    -- (every three hours at most: a start of KOReader or Wi-Fi coming on
    -- asks again, so a new version is offered the same day, not the next)
    if os.time() - last < 3 * 3600 then return end
    M.check()
end

-- ---------------------------------------------------------------- install

local function statusFile() return cacheDir() .. "/install.lua" end

--- Recursively remove a folder (inside the plugins folder only).
local function purge(path)
    local _dir, parent = M.paths()
    if not path or path:sub(1, #parent + 1) ~= parent .. "/" then return end
    if lfs.attributes(path, "mode") == "directory" then pcall(require("ffi/util").purgeDir, path) end
end

--- In the child: download, verify, unpack into the staging folder.
local function stage(rel, staging)
    local status = { ok = false }
    local function fail(why) status.err = why end
    local zip = cacheDir() .. "/update.zip"
    local tmp = zip .. ".part"
    pcall(os.remove, tmp)
    pcall(os.remove, zip)
    repeat
        -- download (LuaSocket, then curl), to a temporary name
        local done = false
        local okR, http, ltn12, socket, socketutil = pcall(function()
            return require("socket.http"), require("ltn12"), require("socket"), require("socketutil")
        end)
        if okR then
            local f = io.open(tmp, "wb")
            if f then
                local okD, code = pcall(function()
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, 600)
                    local sink = socketutil.file_sink and socketutil.file_sink(f) or ltn12.sink.file(f)
                    local c = socket.skip(1, http.request({
                        url = rel.url, method = "GET", sink = sink, redirect = true,
                        headers = { ["User-Agent"] = "KOReader-ShelfTechUI",
                                    ["Accept"] = "application/octet-stream, */*" },
                    }))
                    socketutil:reset_timeout()
                    return c
                end)
                pcall(function() f:close() end)
                done = okD and tonumber(code) == 200
            end
        end
        if not done then
            pcall(os.remove, tmp)
            local q = require("lib/bookshelf_http").shellQuote
            local r = os.execute(string.format("curl -sfL --connect-timeout 10 --max-time 600 -o %s %s", q(tmp), q(rel.url)))
            done = (r == 0 or r == true) and lfs.attributes(tmp, "mode") == "file"
        end
        if not done then fail(_("the download failed")) break end
        -- the size GitHub gave, and the SHA-256 where it gave one
        local size = lfs.attributes(tmp, "size")
        if rel.size and size ~= rel.size then
            fail(T(_("the download is incomplete (%1 of %2 bytes)"), size or 0, rel.size)) break
        end
        if rel.digest then
            local h = io.popen("sha256sum " .. require("lib/bookshelf_http").shellQuote(tmp) .. " 2>/dev/null")
            local line = h and h:read("*l") or ""
            if h then h:close() end
            local got = line:match("^(%x+)")
            if got and got:lower() ~= rel.digest:lower() then fail(_("the download doesn't match the release")) break end
        end
        os.rename(tmp, zip)
        -- unpack into the staging folder, without the zip's top folder
        purge(staging)
        lfs.mkdir(staging)
        local okA, Archiver = pcall(require, "ffi/archiver")
        if not (okA and Archiver and Archiver.Reader) then fail(_("this KOReader can't unpack zips")) break end
        local arc = Archiver.Reader:new()
        if not arc:open(zip) then fail(_("the zip couldn't be opened")) arc:close() break end
        local err
        for entry in arc:iterate() do
            local rel_path = entry.path and entry.path:match("^[^/]+/(.+)$")
            local plain = entry.mode == nil or entry.mode == "file" or entry.mode == "directory"
            if rel_path and rel_path ~= "" and plain and not rel_path:find("%.%.") then
                if not arc:extractToPath(entry.path, staging .. "/" .. rel_path) then
                    err = arc.err or "extract failed"
                    break
                end
            end
        end
        arc:close()
        pcall(os.remove, zip)
        if err then fail(_("unpacking failed") .. " (" .. tostring(err) .. ")") break end
        status.ok = true
    until true
    local s = require("luasettings"):open(statusFile())
    s:saveSetting("status", status)
    s:flush()
end

--- Swap the folders: running → .stui-previous, staged → running. Undone if
--- the second rename fails.
local function swap(staging)
    local dir, parent = M.paths()
    local prev = parent .. "/" .. M.PREVIOUS
    purge(prev)
    if not os.rename(dir, prev) then return false, "rename" end
    if not os.rename(staging, dir) then
        os.rename(prev, dir)
        return false, "rename"
    end
    -- the Transfer server must stay runnable
    pcall(os.execute, "chmod +x " .. require("lib/bookshelf_http").shellQuote(dir .. "/transfer/filebrowser") .. " 2>/dev/null")
    return true
end

local function restartPrompt(text)
    -- at once: the old code is still loaded, the new files are in place
    UIManager:show(InfoMessage:new{ text = text })
    UIManager:forceRePaint()
    UIManager:scheduleIn(1, function() UIManager:restartKOReader() end)
end

M._installing = false

function M.install(rel)
    if M._installing or not (rel and rel.url) then return end
    local _dir, parent = M.paths()
    local staging = parent .. "/" .. M.STAGING
    local ffiutil = require("ffi/util")
    pcall(os.remove, statusFile())
    local ok, pid = pcall(ffiutil.runInSubProcess, function()
        local okS, err = pcall(stage, rel, staging)
        if not okS then
            local s = require("luasettings"):open(statusFile())
            s:saveSetting("status", { ok = false, err = tostring(err) })
            s:flush()
        end
    end)
    if not ok or not pid then
        UIManager:show(InfoMessage:new{ text = _("The update couldn't start."), timeout = 3 })
        return
    end
    M._installing = true
    local total = rel.size or 0
    local msg
    local function show(text)
        if msg then UIManager:close(msg) end
        msg = InfoMessage:new{ text = text }
        UIManager:show(msg)
    end
    show(T(_("Downloading ShelfTechUI %1…"), rel.version))
    local waited, last_shown = 0, -1
    local function poll()
        if not ffiutil.isSubProcessDone(pid) and waited < 900 then
            waited = waited + 1
            -- how far along, every few seconds (not every second: e-ink)
            if waited % 3 == 0 and total > 0 then
                local got = lfs.attributes(cacheDir() .. "/update.zip.part", "size")
                    or lfs.attributes(cacheDir() .. "/update.zip", "size") or 0
                local pct = math.floor(got * 100 / total)
                if pct ~= last_shown then
                    last_shown = pct
                    show(T(_("Downloading ShelfTechUI %1… %2%"), rel.version, math.min(100, pct)))
                end
            end
            UIManager:scheduleIn(1, poll)
            return
        end
        M._installing = false
        if msg then UIManager:close(msg) end
        local s = require("luasettings"):open(statusFile())
        local st = s:readSetting("status") or { ok = false, err = _("it took too long") }
        local meta = st.ok and readMeta(staging)
        if not st.ok or not (meta and meta.name == "shelftechui" and tostring(meta.version) == tostring(rel.version)) then
            purge(staging)
            UIManager:show(InfoMessage:new{
                text = T(_("The update wasn't installed: %1. Nothing was changed."),
                    st.err or _("the download isn't the right version")),
            })
            return
        end
        local okW = swap(staging)
        if not okW then
            purge(staging)
            UIManager:show(InfoMessage:new{ text = _("The update wasn't installed: the plugin folder couldn't be replaced. Nothing was changed.") })
            return
        end
        Store.set("update_seen", rel.version)
        restartPrompt(T(_("ShelfTechUI %1 is installed. Restarting KOReader…"), rel.version))
    end
    UIManager:scheduleIn(1, poll)
end

--- The version from before the last update, back.
function M.rollback()
    local prev = M.previous()
    if not prev then return end
    UIManager:show(ConfirmBox:new{
        text = T(_("Go back to ShelfTechUI %1? KOReader restarts."), prev),
        ok_text = _("Go back"),
        ok_callback = function()
            local dir, parent = M.paths()
            local prev_dir = parent .. "/" .. M.PREVIOUS
            local hold = parent .. "/" .. M.STAGING
            purge(hold)
            -- current → staging name, previous → current, then the (newer)
            -- one becomes the kept previous: go back and forth freely
            if not os.rename(dir, hold) then return end
            if not os.rename(prev_dir, dir) then os.rename(hold, dir) return end
            os.rename(hold, prev_dir)
            Store.set("update_seen", M.installed())
            restartPrompt(T(_("Back to ShelfTechUI %1. Restarting KOReader…"), prev))
        end,
    })
end

-- ---------------------------------------------------------------- Settings → System

function M.settingsItems()
    return {
        {
            text = _("Check for ShelfTechUI updates"),
            description_func = function()
                -- what the last check found, and when
                local r = readResult()
                local last = tonumber(Store.get("update_last_check")) or 0
                local when
                if last > 0 then
                    local mins = math.floor((os.time() - last) / 60)
                    when = mins < 1 and _("just now") or mins < 60 and T(_("%1 min ago"), mins)
                        or mins < 48 * 60 and T(_("%1 h ago"), math.floor(mins / 60)) or T(_("%1 days ago"), math.floor(mins / 1440))
                end
                local state
                if not when then state = _("Not checked yet.")
                elseif r and r.ok and r.release then
                    state = M.available() and T(_("Last checked %1: %2 is available (you have %3)."), when, r.release.version, M.installed())
                        or T(_("Last checked %1: you have the newest version (%2)."), when, M.installed())
                elseif r and r.ok then state = T(_("Last checked %1: no release found."), when)
                else state = T(_("Last checked %1: GitHub couldn't be reached%2."), when,
                    (r and r.error and r.error ~= "no answer") and (" (" .. r.error .. ")") or "") end
                return state .. " " .. _("Tap to check now (Wi-Fi): a newer version shows what's new, downloads, is checked, and KOReader restarts. Nothing changes if anything goes wrong.")
            end,
            mandatory_func = function()
                local rel = M.available()
                return rel and T(_("%1 available"), rel.version) or M.installed()
            end,
            keep_menu_open = true,
            callback = function() M.check({ manual = true }) end,
        },
        {
            text = _("Check automatically"),
            description = _("When KOReader starts and when Wi-Fi comes on (every three hours at most). A new version is offered once, on home, never over a book; it stays in this list until you install it."),
            checked_func = function() return Store.get("update_auto") ~= false end,
            callback = function() Store.set("update_auto", Store.get("update_auto") == false and true or false) end,
        },
        {
            text = _("Include beta versions"),
            description = _("Also offer test versions published before a release."),
            checked_func = function() return Store.get("update_beta") == true end,
            callback = function() Store.set("update_beta", Store.get("update_beta") ~= true or nil) end,
        },
        {
            text_func = function()
                local prev = M.previous()
                return prev and T(_("Go back to %1"), prev) or _("Go back to the previous version")
            end,
            description = _("The version from before the last update is kept, so you can go back to it (and forward again)."),
            enabled_func = function() return M.previous() ~= nil end,
            callback = function() M.rollback() end,
        },
    }
end

return M
