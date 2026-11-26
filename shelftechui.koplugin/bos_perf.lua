--[[
Slow steps, written down (for finding hiccups on a device).

Off unless the file koreader/settings/stui_perf exists. Then every step that
holds the screen up longer than a moment is logged to crash.log as

    ShelfTechUI perf: <ms> ms  <what>

where <what> is one of
    event <Handler> in <module>   a module (KOReader's, a plugin's, ours)
                                  handling an event (opening, closing,
                                  turning a page, resuming…)
    task <where>                  something scheduled to run later
    paint <widgets>               drawing the screen
    show <widget> / close <widget>

so a hiccup can be put down to whoever caused it.

A step that goes on for more than STALL_MS (3 s) is also caught in the act:
a light hook looks at the clock every few thousand Lua instructions, and the
first time it finds the step past 3 s it writes where the code is then

    ShelfTechUI perf: stall 3012 ms in <what>, at:
      <a short stack: file:line in function, innermost first>

(LuaJIT runs no hooks in compiled code, so this catches long Lua loops
only some of the time.) The calls that can block for seconds are timed
themselves, which always works: a DNS lookup, an HTTP(S) request, a call to
the Kindle's system services (lipc), a shell command. One over SLOW_CALL_MS
(1 s) is written down with who made it:

    ShelfTechUI perf: slow call 10004 ms  socket.dns.toip(api.hardcover.app), from:
      <a short stack>

  M.install()     once, at start (does nothing when off)
  M.watch(ui)     a ReaderUI or FileManager: its modules, timed
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

local THRESHOLD_MS = tonumber(os.getenv("STUI_PERF_MS") or "") or 80

local function now()
    local ok, t = pcall(function() local TM = require("ui/time") return TM.to_ms(TM.now()) end)
    return ok and t or os.clock() * 1000
end

function M.on()
    if M._on == nil then
        local lfs = require("libs/libkoreader-lfs")
        M._on = lfs.attributes(require("datastorage"):getSettingsDir() .. "/stui_perf", "mode") == "file"
    end
    return M._on
end

local STALL_MS = tonumber(os.getenv("STUI_PERF_STALL_MS") or "") or 3000

-- The outermost step being timed: when it started, what it is, whether its
-- stall was written down already. Nested steps (a task run while painting)
-- belong to it.
local step = nil

local function stallHook()
    local st = step
    if not st or st.done then return end
    local ms = (function()
        local ok, t = pcall(function() local TM = require("ui/time") return TM.to_ms(TM.now()) end)
        return ok and t or os.clock() * 1000
    end)() - st.t0
    if ms < STALL_MS then return end
    st.done = true
    logger.info(string.format("ShelfTechUI perf: stall %d ms in %s, at:\n%s", ms, st.what, M._stack(3)))
end

-- Times fn as the step `what`: the outermost step gets the stall hook.
local function timed(what, fn, ...)
    if step then return fn(...) end
    step = { t0 = nil, what = what }
    local okT, t = pcall(function() local TM = require("ui/time") return TM.to_ms(TM.now()) end)
    step.t0 = okT and t or os.clock() * 1000
    debug.sethook(stallHook, "", 5000)
    local r = table.pack(pcall(fn, ...))
    debug.sethook()
    step = nil
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, r.n)
end
M._timed = timed

local SLOW_CALL_MS = tonumber(os.getenv("STUI_PERF_CALL_MS") or "") or 1000

local function stackLines(from)
    local lines = {}
    for level = from, from + 14 do
        local info = debug.getinfo(level, "Sln")
        if not info then break end
        if info.what ~= "C" then
            lines[#lines + 1] = string.format("  %s:%s in %s",
                (info.short_src or "?"):gsub("^.*/plugins/", ""):gsub("^.*frontend/", ""),
                tostring(info.currentline), tostring(info.name or "?"))
        end
    end
    return table.concat(lines, "\n")
end

--- fn, timed as a call that may block: logged with its caller when slow.
M._stack = function(from) return stackLines(from) end

function M.timeCall(name, fn, describe)
    return function(...)
        local t0 = now()
        local r = table.pack(fn(...))
        local ms = now() - t0
        if ms > SLOW_CALL_MS then
            local what = name
            if describe then
                local ok, d = pcall(describe, ...)
                if ok and d then what = what .. "(" .. tostring(d):sub(1, 80) .. ")" end
            end
            logger.info(string.format("ShelfTechUI perf: slow call %d ms  %s, from:\n%s", ms, what, stackLines(3)))
        end
        return unpack(r, 1, r.n)
    end
end

-- The calls that can hold the screen for seconds, each timed.
local function watchCalls()
    local function wrapField(t, key, name, describe)
        if type(t) == "table" and type(t[key]) == "function" and not (M._calls and M._calls[t[key]]) then
            local w = M.timeCall(name, t[key], describe)
            M._calls = M._calls or setmetatable({}, { __mode = "k" })
            M._calls[w] = true
            t[key] = w
        end
    end
    local function first(a) return a end
    local function urlOf(a) return type(a) == "table" and a.url or a end
    pcall(function()
        local dns = require("socket").dns
        for _i, k in ipairs({ "toip", "getaddrinfo", "tohostname", "getnameinfo" }) do wrapField(dns, k, "socket.dns." .. k, first) end
    end)
    pcall(function() wrapField(require("socket.http"), "request", "http.request", urlOf) end)
    pcall(function() wrapField(require("ssl.https"), "request", "https.request", urlOf) end)
    wrapField(io, "popen", "io.popen", first)
    wrapField(os, "execute", "os.execute", first)
    -- the Kindle's system services: each handle's calls
    for _i, modname in ipairs({ "liblipclua", "libopenlipclua" }) do
        pcall(function()
            local lipc = require(modname)
            for _j, opener in ipairs({ "init", "open", "open_no_name" }) do
                local orig = lipc[opener]
                if type(orig) == "function" then
                    lipc[opener] = function(...)
                        local h = orig(...)
                        if h and not (M._handles and M._handles[h]) then
                            M._handles = M._handles or setmetatable({}, { __mode = "k" })
                            M._handles[h] = true
                            local mt = getmetatable(h)
                            local idx = mt and mt.__index
                            if type(idx) == "table" and not idx._stui_perf then
                                idx._stui_perf = true
                                for k, f in pairs(idx) do
                                    if type(f) == "function" and (k:match("^get_") or k:match("^set_") or k:match("^access_")) then
                                        idx[k] = M.timeCall("lipc " .. k, f, function(_self, a, b) return tostring(a) .. " " .. tostring(b) end)
                                    end
                                end
                            end
                        end
                        return h
                    end
                end
            end
        end)
    end
end
M._watchCalls = watchCalls

local function log(ms, what)
    logger.info(string.format("ShelfTechUI perf: %4d ms  %s", ms, what))
end

local function nameOf(w)
    if type(w) ~= "table" then return tostring(w) end
    return w.name or w.id or (w.title and ("\"" .. tostring(w.title):sub(1, 30) .. "\"")) or "?"
end

--- Where a function was written (file:line), for a scheduled task.
local function whereOf(fn)
    local ok, info = pcall(debug.getinfo, fn, "S")
    if not ok or not info then return "?" end
    return (info.short_src or "?"):gsub("^.*/plugins/", ""):gsub("^.*frontend/", "") .. ":" .. tostring(info.linedefined)
end

function M.install()
    if not M.on() or M._installed then return end
    M._installed = true
    logger.info("ShelfTechUI perf: on (koreader/settings/stui_perf); steps over " .. THRESHOLD_MS .. " ms are logged")
    pcall(watchCalls)
    -- scheduled tasks, each timed as it runs
    local orig_schedule = UIManager.schedule
    UIManager.schedule = function(self, sched_time, action, ...)
        if type(action) == "function" then
            local fn = action
            local wrapped = function(...)
                local t0 = now()
                local r = table.pack(timed("task " .. whereOf(fn), fn, ...))
                local ms = now() - t0
                if ms > THRESHOLD_MS then log(ms, "task " .. whereOf(fn)) end
                return unpack(r, 1, r.n)
            end
            -- (unschedule finds tasks by their action: the original is kept
            -- beside the wrapper, and unschedule looks for either)
            M._wrapped = M._wrapped or setmetatable({}, { __mode = "k" })
            M._wrapped[fn] = M._wrapped[fn] or {}
            table.insert(M._wrapped[fn], wrapped)
            return orig_schedule(self, sched_time, wrapped, ...)
        end
        return orig_schedule(self, sched_time, action, ...)
    end
    local orig_unschedule = UIManager.unschedule
    UIManager.unschedule = function(self, action)
        local r = orig_unschedule(self, action)
        local list = M._wrapped and M._wrapped[action]
        if list then
            for _i, w in ipairs(list) do orig_unschedule(self, w) end
            M._wrapped[action] = nil
        end
        return r
    end
    -- drawing the screen
    local orig_repaint = UIManager._repaint
    UIManager._repaint = function(self, ...)
        local names = {}
        for w in pairs(self._dirty or {}) do
            if type(w) == "table" and #names < 4 then names[#names + 1] = nameOf(w) end
        end
        local t0 = now()
        local r = table.pack(timed("paint " .. table.concat(names, ", "), orig_repaint, self, ...))
        local ms = now() - t0
        if ms > THRESHOLD_MS then log(ms, "paint " .. table.concat(names, ", ")) end
        return unpack(r, 1, r.n)
    end
    for _i, which in ipairs({ "show", "close" }) do
        local orig = UIManager[which]
        UIManager[which] = function(self, widget, ...)
            local t0 = now()
            local r = table.pack(orig(self, widget, ...))
            local ms = now() - t0
            if ms > THRESHOLD_MS then log(ms, which .. " " .. nameOf(widget)) end
            return unpack(r, 1, r.n)
        end
    end
end

--- Time each module of a UI (KOReader's reader or file browser) as it
--- handles events: a slow one is logged with its name and the event.
function M.watch(ui)
    if not M.on() or type(ui) ~= "table" or ui._stui_perf then return end
    ui._stui_perf = true
    local function wrap(mod, name)
        if type(mod) ~= "table" or mod._stui_perf or type(mod.handleEvent) ~= "function" then return end
        mod._stui_perf = true
        local orig = mod.handleEvent
        mod.handleEvent = function(self, event, ...)
            local t0 = now()
            local r = table.pack(timed("event " .. tostring(event and event.handler) .. " in " .. name, orig, self, event, ...))
            local ms = now() - t0
            if ms > THRESHOLD_MS then
                log(ms, "event " .. tostring(event and event.handler) .. " in " .. name)
            end
            return unpack(r, 1, r.n)
        end
    end
    -- the modules are the UI's own fields (ui.bookshelf, ui.highlight…)
    for k, v in pairs(ui) do
        if type(k) == "string" and type(v) == "table" and v ~= ui and rawget(v, "ui") == ui then
            pcall(wrap, v, k)
        end
    end
end

return M
