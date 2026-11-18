--[[
KOReader's progress sync (KOSync), without the wait.

KOSync pulls the position when a book opens and pushes it when the book
closes, and on a Kindle it does both on the spot: the screen waits for the
server (up to 2 s to connect, 5 s in all; on the Paperwhite each took ~2.2 s,
once 7 s, every time a book was opened or closed). Here those two requests
are made by a background process; KOSync's own handling of the answer runs
when it comes (a pull's answer only if the same book is still open).

Nothing of KOSync is changed but where its two requests run; its settings,
login and the like are as they were. Off: Settings → Reading → Progress sync
in the background.

  M.install(ui)   a reader's KOSync (once; does nothing without KOSync)
--]]

local logger = require("logger")

local M = {}

function M.enabled() return require("bos_settings_store").get("kosync_background") ~= false end

-- what can be passed back from the background (no functions or userdata,
-- such as a JSON null)
local function plain(v, depth)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then return v end
    if t ~= "table" or (depth or 0) > 6 then return nil end
    local out = {}
    for k, x in pairs(v) do
        local kk = (type(k) == "string" or type(k) == "number") and k or nil
        if kk ~= nil then out[kk] = plain(x, (depth or 0) + 1) end
    end
    return out
end

local function clientModule(ui)
    local Client = package.loaded["KOSyncClient"]
    if type(Client) == "table" then return Client end
    local ok, mod = pcall(require, "KOSyncClient")
    if (not ok or type(mod) ~= "table") and ui.kosync and ui.kosync.path then
        ok, mod = pcall(dofile, ui.kosync.path .. "/KOSyncClient.lua")
        if ok and type(mod) == "table" then package.loaded["KOSyncClient"] = mod end
    end
    return ok and type(mod) == "table" and mod or nil
end

function M.install(ui)
    if M._installed or not (ui and ui.kosync) then return end
    local Client = clientModule(ui)
    if not Client or Client._stui_bg then return end
    M._installed = true
    Client._stui_bg = true
    for _i, name in ipairs({ "get_progress", "update_progress" }) do
        local orig = Client[name]
        if type(orig) == "function" then
            Client[name] = function(self, ...)
                local args = table.pack(...)
                local cb = args[args.n]
                if not M.enabled() or type(cb) ~= "function" then return orig(self, ...) end
                -- the book it's for (a pull's answer is only used if it's still open)
                local ReaderUI = package.loaded["apps/reader/readerui"]
                local reader = ReaderUI and ReaderUI.instance
                local doc = reader and reader.document
                local Async = require("bos_store").Async
                Async.run(function()
                    local got
                    local call = { unpack(args, 1, args.n - 1) }
                    call[args.n] = function(...) got = table.pack(...) end
                    orig(self, unpack(call, 1, args.n))
                    return plain(got)
                end, function(ok, got)
                    if not (ok and type(got) == "table") then
                        logger.info("ShelfTechUI: progress sync in the background didn't answer:", name, tostring(got))
                        got = { n = 3, false }
                    end
                    if name == "get_progress" then
                        local now = ReaderUI and ReaderUI.instance
                        if not (doc and now == reader and reader.document == doc) then return end
                    end
                    local okC, err = pcall(cb, unpack(got, 1, got.n or 3))
                    if not okC then logger.warn("ShelfTechUI: progress sync answer:", err) end
                end, 20)
            end
        end
    end
    logger.dbg("ShelfTechUI: KOSync's requests run in the background")
end

return M
