--[[
Network work off the main loop, in parallel, and cancellable.

Each task runs in its own forked process (so a slow library can't freeze the
device), its result comes back through a pipe, and while waiting the UI stays
live: taps work, and Cancel stops everything at once.

    local results, cancelled = Jobs.run({
        { key = "gutenberg", fn = function() return OPDS:searchSource(…) end },
        { key = "internet_archive", fn = function() return IA:search(…) end },
    }, { timeout = 25, cancelled = function() return loading.cancelled end })
    -- results[key] = { ok = true, n = 2, [1] = result, [2] = err }
    --             or { ok = false, err = "timed out" }

Must be called from a coroutine (Trapper:wrap); outside one it runs the
tasks one after another, in this process.
--]]

local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local okBuf, buffer = pcall(require, "string.buffer")

local Jobs = {}

local function encode(v)
    if okBuf then
        local ok, s = pcall(buffer.encode, v)
        if ok then return s end
    end
end

local function decode(s)
    if okBuf and s and s ~= "" then
        local ok, v = pcall(buffer.decode, s)
        if ok then return v end
    end
end

--- Kill and collect a child in the background (no zombies).
local function reap(job)
    if not job.pid then return end
    pcall(ffiutil.terminateSubProcess, job.pid)
    local pid, fd = job.pid, job.fd
    job.pid = nil
    local function collect()
        if ffiutil.isSubProcessDone(pid) then
            if fd then pcall(ffiutil.readAllFromFD, fd) end
        else
            if fd and ffiutil.getNonBlockingReadSize(fd) ~= 0 then
                pcall(ffiutil.readAllFromFD, fd)
                fd = nil
            end
            UIManager:scheduleIn(2, collect)
        end
    end
    UIManager:scheduleIn(1, collect)
end

local function inline(tasks)
    local results = {}
    for _i, t in ipairs(tasks) do
        local r = table.pack(pcall(t.fn))
        if r[1] then
            results[t.key] = { ok = true, n = r.n - 1, unpack(r, 2, r.n) }
        else
            results[t.key] = { ok = false, err = tostring(r[2]) }
        end
    end
    return results, false
end

--- opts: timeout (seconds, whole run), cancelled() -> bool, on_progress(done, total)
function Jobs.run(tasks, opts)
    opts = opts or {}
    local co = coroutine.running()
    if not co or not okBuf then return inline(tasks) end

    local jobs = {}
    for _i, t in ipairs(tasks) do
        local job = { key = t.key }
        local pid, fd = ffiutil.runInSubProcess(function(_pid, wfd)
            local r = table.pack(pcall(t.fn))
            local out
            if r[1] then
                out = encode({ ok = true, n = r.n - 1, unpack(r, 2, r.n) })
            else
                out = encode({ ok = false, err = tostring(r[2]) })
            end
            ffiutil.writeToFD(wfd, out or encode({ ok = false, err = "result could not be passed back" }) or "", true)
        end, true)
        if pid then
            job.pid, job.fd = pid, fd
        else
            -- no fork here: do it in-process
            local r = table.pack(pcall(t.fn))
            job.result = r[1] and { ok = true, n = r.n - 1, unpack(r, 2, r.n) } or { ok = false, err = tostring(r[2]) }
        end
        table.insert(jobs, job)
    end

    local results = {}
    local deadline = os.time() + (opts.timeout or 30)
    local interval = 0.1
    local cancelled = false
    while true do
        local pending = 0
        local done = 0
        for _i, job in ipairs(jobs) do
            if job.result then
                results[job.key] = results[job.key] or job.result
                done = done + 1
            elseif job.pid then
                local ready = job.fd and ffiutil.getNonBlockingReadSize(job.fd) ~= 0
                if ready or ffiutil.isSubProcessDone(job.pid) then
                    local s = job.fd and ffiutil.readAllFromFD(job.fd) or ""
                    job.fd = nil
                    job.result = decode(s) or { ok = false, err = "no answer" }
                    -- collect it
                    local pid = job.pid
                    job.pid = nil
                    if not ffiutil.isSubProcessDone(pid) then
                        UIManager:scheduleIn(1, function() ffiutil.isSubProcessDone(pid, true) end)
                    end
                    results[job.key] = job.result
                    done = done + 1
                else
                    pending = pending + 1
                end
            end
        end
        if opts.on_progress then pcall(opts.on_progress, done, #jobs) end
        if pending == 0 then break end
        if opts.cancelled and opts.cancelled() then
            cancelled = true
            for _i, job in ipairs(jobs) do reap(job) end
            break
        end
        if os.time() > deadline then
            for _i, job in ipairs(jobs) do
                if job.pid then
                    reap(job)
                    results[job.key] = { ok = false, err = "timed out" }
                end
            end
            break
        end
        -- let the UI breathe (taps, Cancel) until the next look
        UIManager:scheduleIn(interval, function() coroutine.resume(co) end)
        coroutine.yield()
        interval = math.min(interval * 1.5, 0.5)
    end
    return results, cancelled
end

return Jobs
