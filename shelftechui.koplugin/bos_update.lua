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
    -- (an error comes back as a table too: { message = ... })
    if type(list) == "table" and list.message and not list[1] then list = nil end
    if list and list[1] and type(list[1]) == "table" and list[1].message and not list[1].tag_name then list = nil end
    local out = { at = os.time(), ok = list ~= nil }
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
function M.offer(rel)
    if not rel then return end
    local size = rel.size and string.format(" (%.1f MB)", rel.size / 1048576) or ""
    local text = T(_("ShelfTechUI %1 is available. You have %2."), rel.version, M.installed())
        .. "\n\n" .. cleanNotes(rel.notes)
        .. "\n\n" .. T(_("Download it%1 and restart KOReader?"), size)
    UIManager:show(ConfirmBox:new{
        text = text,
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
                UIManager:show(InfoMessage:new{ text = _("Couldn't reach GitHub. Check the Wi-Fi and try again."), timeout = 4 })
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
    if os.time() - last < 20 * 3600 then return end
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
            text = _("Check for updates"),
            description = _("Asks GitHub for a newer ShelfTechUI (Wi-Fi). If there is one, it shows what's new, then downloads it, checks it and restarts KOReader. Nothing changes if anything goes wrong."),
            mandatory_func = function()
                local rel = M.available()
                return rel and T(_("%1 available"), rel.version) or M.installed()
            end,
            keep_menu_open = true,
            callback = function() M.check({ manual = true }) end,
        },
        {
            text = _("Check automatically"),
            description = _("Once a day, when Wi-Fi is on. A new version is offered once, on home, never over a book."),
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
