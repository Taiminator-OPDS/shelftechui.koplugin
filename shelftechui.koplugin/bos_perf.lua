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

  M.install()     once, at start (does nothing when off)
  M.watch(ui)     a ReaderUI or FileManager: its modules, timed
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

local THRESHOLD_MS = 80

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
    -- scheduled tasks, each timed as it runs
    local orig_schedule = UIManager.schedule
    UIManager.schedule = function(self, sched_time, action, ...)
        if type(action) == "function" then
            local fn = action
            local wrapped = function(...)
                local t0 = now()
                local r = table.pack(fn(...))
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
        local r = table.pack(orig_repaint(self, ...))
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
            local r = table.pack(orig(self, event, ...))
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
