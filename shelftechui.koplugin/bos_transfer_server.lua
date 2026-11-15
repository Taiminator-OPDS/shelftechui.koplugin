--[[
Transfer's web server: a small one of ShelfTechUI's own, inside KOReader.

It serves one page (transfer/index.html, in ShelfTechUI's look) and a few
calls the page makes:

  GET  /                       the page (or, when a code is asked, the
                               page that asks for it)
  GET  /?k=CODE                the address in the QR code: signs the
                               browser in and is the page
  POST /login                  the code typed in (form field "code")
  GET  /api/list?dir=…         a folder: its folders and files, as JSON
  POST /api/upload?dir=…&name=…  a file, sent as the request's body;
                               written to "name.part", then renamed
  GET  /api/file?path=…        a file, to download
  GET  /api/zip?path=…         a folder and all that's in it, as a zip
                               made on the way out
  POST /api/delete?path=…      a file (and its KOReader sidecar folder),
                               or an empty folder
  POST /api/mkdir?dir=…&name=…  a new folder

Paths: "Comics/Saga 01.cbz" is inside the shared folder (where the page
opens); "/mnt/us/documents" is anywhere on the device, which is allowed
only while a code is asked for (without one the page stays inside the
shared folder, since anyone on the Wi-Fi could open it). ".." is refused.

It never blocks KOReader: the sockets are non-blocking, the server is
looked at by a timer on KOReader's own loop (every 0.2 s while idle, at
once while something is moving), and each look moves at most a few
hundred kilobytes per connection before giving KOReader its turn back. A
book of 50 MB comes in a slice at a time while the page still turns.

  M.start{ root, port, code, on_received(path), on_change(), on_visit(ip) }  → true | nil, why
  M.stop()
  M.running()       → port | nil
  M.busy()          → true while a file is coming in or going out
--]]

local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local M = {}

local S = nil -- the server's state while it's on

local IDLE_EVERY = 0.2          -- s between looks when nothing is moving
local BUDGET = 384 * 1024       -- bytes moved per connection per look
local CHUNK = 64 * 1024
local MAX_HEAD = 16 * 1024
local MAX_UPLOAD = 2 * 1024 * 1024 * 1024
local IDLE_TIMEOUT = 60         -- s a connection may sit without moving

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".")

-- ---------------------------------------------------------------- helpers

local function now() return os.time() end

local function urldecode(s)
    s = tostring(s or ""):gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parseQuery(q)
    local t = {}
    for k, v in tostring(q or ""):gmatch("([^&=]+)=?([^&]*)") do t[urldecode(k)] = urldecode(v) end
    return t
end

local function jsonEscape(s)
    s = tostring(s or "")
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
        elseif c == "\n" then return "\\n" elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
        return string.format("\\u%04x", c:byte())
    end)
    return s
end

local function toJSON(v)
    local t = type(v)
    if t == "table" then
        if v[1] ~= nil or next(v) == nil and v.__array then
            local out = {}
            for i = 1, #v do out[i] = toJSON(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local out = {}
        for k, x in pairs(v) do
            if k ~= "__array" then out[#out + 1] = '"' .. jsonEscape(k) .. '":' .. toJSON(x) end
        end
        return "{" .. table.concat(out, ",") .. "}"
    elseif t == "string" then return '"' .. jsonEscape(v) .. '"'
    elseif t == "number" then return tostring(v)
    elseif t == "boolean" then return v and "true" or "false" end
    return "null"
end

--- The path the page means, or nil. `rel` is what it sent: "" (the shared
--- folder itself), "Comics", "Comics/Saga 01.cbz"… or, with a leading
--- slash, a path anywhere on the device ("/", "/mnt/us/fonts").
local function inside(rel)
    rel = tostring(rel or ""):gsub("\\", "/")
    local anywhere = rel:sub(1, 1) == "/"
    if anywhere and not S.wide then return nil end
    local parts = {}
    for p in rel:gmatch("[^/]+") do
        if p == ".." then return nil end
        if p ~= "." and p ~= "" then parts[#parts + 1] = p end
    end
    for _i, p in ipairs(parts) do
        if p:find("%z") then return nil end
    end
    local clean = table.concat(parts, "/")
    if anywhere then return "/" .. clean, "/" .. clean end
    return S.root .. (clean ~= "" and ("/" .. clean) or ""), clean
end

--- A name for a file or folder: no slashes, nothing hidden, not too long.
local function safeName(name)
    name = tostring(name or ""):gsub("[/\\%z]", "_"):gsub("^%.+", ""):gsub("[%c]", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 200 then
        local ext = name:match("(%.[^.]+)$") or ""
        name = name:sub(1, 200 - #ext) .. ext
    end
    return name ~= "" and name or nil
end

local MIME = {
    epub = "application/epub+zip", pdf = "application/pdf", mobi = "application/x-mobipocket-ebook",
    azw3 = "application/vnd.amazon.ebook", cbz = "application/vnd.comicbook+zip", fb2 = "application/x-fictionbook+xml",
    txt = "text/plain; charset=utf-8", html = "text/html; charset=utf-8", png = "image/png", jpg = "image/jpeg",
    jpeg = "image/jpeg", json = "application/json",
}

-- ---------------------------------------------------------------- responses

local STATUS = { [200] = "OK", [302] = "Found", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
    [405] = "Method Not Allowed", [409] = "Conflict", [411] = "Length Required", [413] = "Payload Too Large",
    [500] = "Internal Server Error", [507] = "Insufficient Storage" }

local function respond(c, code, ctype, body, extra)
    body = body or ""
    local head = { "HTTP/1.1 " .. code .. " " .. (STATUS[code] or "OK"),
        "Content-Type: " .. (ctype or "text/plain; charset=utf-8"),
        "Content-Length: " .. #body, "Cache-Control: no-store", "Connection: close" }
    for _i, h in ipairs(extra or {}) do head[#head + 1] = h end
    c.out = table.concat(head, "\r\n") .. "\r\n\r\n" .. body
    c.out_pos = 1
    c.state = "send"
end

local function json(c, code, t, extra) respond(c, code, "application/json; charset=utf-8", toJSON(t), extra) end

local function fail(c, code, msg) json(c, code, { error = msg }) end

local function sendFile(c, path, name)
    local f = io.open(path, "rb")
    if not f then return fail(c, 404, "Not found") end
    local size = lfs.attributes(path, "size") or 0
    local ext = (name:match("%.([^.]+)$") or ""):lower()
    local head = { "HTTP/1.1 200 OK", "Content-Type: " .. (MIME[ext] or "application/octet-stream"),
        "Content-Length: " .. size, "Cache-Control: no-store", "Connection: close",
        -- (RFC 5987: names in any language survive)
        "Content-Disposition: attachment; filename=\"" .. name:gsub('[^%w%._%- ]', "_") .. "\"; filename*=UTF-8''"
            .. name:gsub("[^%w%._%-]", function(ch) return string.format("%%%02X", ch:byte()) end) }
    c.out = table.concat(head, "\r\n") .. "\r\n\r\n"
    c.out_pos = 1
    c.file_out = f
    c.state = "send"
    S.moving = S.moving + 1
    c.counted = true
end

-- ---------------------------------------------------------------- a folder, as a zip

-- A folder is sent as a zip made on the way out: files stored as they are
-- (books are compressed already), each followed by its checksum, the index
-- at the end. Nothing is written to the device and nothing is held in
-- memory but the piece being sent.

local bit = require("bit")
local crc32
do
    local ok, z = pcall(function()
        local ffi = require("ffi")
        require("ffi/zlib_h")
        local lib = ffi.loadlib and ffi.loadlib("z", 1) or ffi.load("z")
        return function(crc, str) return tonumber(lib.crc32(crc, str, #str)) end
    end)
    if ok and z and pcall(z, 0, "x") then
        crc32 = z
    else
        local tab = {}
        for i = 0, 255 do
            local c = i
            for _k = 1, 8 do
                c = bit.band(c, 1) == 1 and bit.bxor(bit.rshift(c, 1), 0xEDB88320) or bit.rshift(c, 1)
            end
            tab[i] = c
        end
        crc32 = function(crc, str)
            local c = bit.bnot(crc)
            for i = 1, #str do
                c = bit.bxor(bit.rshift(c, 8), tab[bit.band(bit.bxor(c, str:byte(i)), 0xFF)])
            end
            c = bit.bnot(c)
            return c < 0 and c + 4294967296 or c
        end
    end
end

local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function dosTime(t)
    local d = os.date("*t", t or os.time())
    if d.year < 1980 then d = { year = 1980, month = 1, day = 1, hour = 0, min = 0, sec = 0 } end
    return d.hour * 2048 + d.min * 32 + math.floor(d.sec / 2), (d.year - 1980) * 512 + d.month * 32 + d.day
end

local ZIP_MAX_FILES = 5000
local ZIP_MAX_BYTES = 4 * 1024 * 1024 * 1024 - 64 * 1024 * 1024

--- Everything in `dir`, as { name (inside the zip), path, size, mtime, dir }.
local function walk(dir, prefix, hidden, out, total)
    local names = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and not name:match("%.part$")
            and (hidden or (not name:match("^%.") and not name:match("%.sdr$"))) then names[#names + 1] = name end
    end
    table.sort(names)
    local had = false
    for _i, name in ipairs(names) do
        local a = lfs.attributes(dir .. "/" .. name)
        if a and a.mode == "directory" then
            had = true
            total = walk(dir .. "/" .. name, prefix .. name .. "/", hidden, out, total)
        elseif a and a.mode == "file" then
            had = true
            out[#out + 1] = { name = prefix .. name, path = dir .. "/" .. name, size = a.size or 0, mtime = a.modification }
            total = total + (a.size or 0)
        end
        if #out > ZIP_MAX_FILES or total > ZIP_MAX_BYTES then return total end
    end
    -- (an empty folder is kept as one)
    if not had and prefix ~= "" then out[#out + 1] = { name = prefix, dir = true, size = 0 } end
    return total
end

local function sendZip(c, dir, label, hidden)
    local entries = {}
    local total = walk(dir, label .. "/", hidden, entries, 0)
    if #entries == 0 then return fail(c, 409, "That folder is empty") end
    if #entries > ZIP_MAX_FILES then return fail(c, 413, "Too many files for one download: download its folders one at a time") end
    if total > ZIP_MAX_BYTES then return fail(c, 413, "More than 4 GB: download its folders one at a time") end
    local head = { "HTTP/1.1 200 OK", "Content-Type: application/zip", "Cache-Control: no-store", "Connection: close",
        "Content-Disposition: attachment; filename=\"" .. label:gsub('[^%w%._%- ]', "_") .. ".zip\"; filename*=UTF-8''"
            .. label:gsub("[^%w%._%-]", function(ch) return string.format("%%%02X", ch:byte()) end) .. ".zip" }
    c.out = table.concat(head, "\r\n") .. "\r\n\r\n"
    c.out_pos = 1
    c.state = "send"
    S.moving = S.moving + 1
    c.counted = true
    local i, offset, central, f, cur = 0, 0, {}, nil, nil
    local done = false
    local function emit(str) offset = offset + #str return str end
    -- the next piece to send (nil: that was all)
    c.more = function()
        if done then return nil end
        if f then
            local chunk = f:read(CHUNK)
            if chunk and #chunk > 0 then
                cur.crc = crc32(cur.crc, chunk)
                cur.sent = cur.sent + #chunk
                return emit(chunk)
            end
            f:close()
            f, c.file_out = nil, nil
            -- its checksum and size, now that they're known
            return emit("PK\7\8" .. le32(cur.crc) .. le32(cur.sent) .. le32(cur.sent))
        end
        if cur then
            local t, d = dosTime(cur.e.mtime)
            central[#central + 1] = "PK\1\2" .. le16(20) .. le16(20) .. le16(cur.flags) .. le16(0) .. le16(t) .. le16(d)
                .. le32(cur.crc) .. le32(cur.sent) .. le32(cur.sent) .. le16(#cur.e.name) .. le16(0) .. le16(0)
                .. le16(0) .. le16(0) .. le32(cur.e.dir and 16 or 0) .. le32(cur.at) .. cur.e.name
            cur = nil
        end
        i = i + 1
        local e = entries[i]
        if not e then
            done = true
            local cd = table.concat(central)
            return cd .. "PK\5\6" .. le16(0) .. le16(0) .. le16(#central) .. le16(#central) .. le32(#cd) .. le32(offset) .. le16(0)
        end
        local t, d = dosTime(e.mtime)
        -- (bit 11: the name is UTF-8; bit 3: sizes follow the data)
        cur = { e = e, crc = 0, sent = 0, at = offset, flags = e.dir and 0x0800 or 0x0808 }
        if not e.dir then
            f = io.open(e.path, "rb")
            c.file_out = f -- (closed with the connection if it's cut)
            if not f then cur.flags = 0x0800 end -- (unreadable: kept as an empty file)
        end
        return emit("PK\3\4" .. le16(20) .. le16(cur.flags) .. le16(0) .. le16(t) .. le16(d) .. le32(0) .. le32(0) .. le32(0)
            .. le16(#e.name) .. le16(0) .. e.name)
    end
end

-- ---------------------------------------------------------------- the page

local page_cache
local function page()
    if page_cache then return page_cache end
    local f = io.open(PLUGIN_DIR .. "/transfer/index.html", "rb")
    page_cache = f and f:read("*a") or "<!doctype html><title>Transfer</title><p>The page is missing from this build."
    if f then f:close() end
    return page_cache
end

-- (Lax, not Strict: a QR scanner or another app opening the address is a
-- visit "from elsewhere", and a Strict cookie isn't sent back after it)
local function COOKIE() return "Set-Cookie: stui_t=" .. S.code .. "; Path=/; HttpOnly; SameSite=Lax" end

--- Signed in: the cookie, or the code itself (the page sends it with every
--- call and puts it on its download links, so nothing depends on a phone's
--- browser keeping a cookie).
local function signedIn(c, q)
    if not S.code then return true end
    local cookie = c.headers["cookie"] or ""
    if cookie:find("stui_t=" .. S.code, 1, true) then return true end
    return c.headers["x-stui-code"] == S.code or (q and q.k == S.code) or false
end

local function loginPage(c, wrong)
    local html = page():gsub("<!%-%-STATE%-%->", '<script>window.STUI_LOGIN=' .. (wrong and "'wrong'" or "true") .. ';</script>', 1)
    respond(c, wrong and 403 or 200, "text/html; charset=utf-8", html)
end

-- ---------------------------------------------------------------- routes

local function list(c, q)
    local dir, rel = inside(q.dir)
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then return fail(c, 404, "No such folder") end
    local folders, files = {}, {}
    for name in lfs.dir(dir) do
        -- (KOReader's own: dot files, and the .sdr folders of book settings,
        -- unless the page asks for hidden things too)
        if name ~= "." and name ~= ".." and (q.hidden == "1" or (not name:match("^%.") and not name:match("%.sdr$"))) then
            local a = lfs.attributes(dir .. "/" .. name)
            if a then
                if a.mode == "directory" then
                    folders[#folders + 1] = { name = name, mtime = a.modification or 0 }
                elseif a.mode == "file" and not name:match("%.part$") then
                    files[#files + 1] = { name = name, size = a.size or 0, mtime = a.modification or 0 }
                end
            end
        end
    end
    table.sort(folders, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a, b) return a.mtime > b.mtime end)
    local free
    pcall(function()
        local u = require("util").diskUsage(dir)
        free = u and u.available
    end)
    folders.__array, files.__array = true, true
    json(c, 200, { dir = rel, folders = folders, files = files, free = free or false, device = S.device or "",
        abs = rel:sub(1, 1) == "/" and rel or dir, home = S.root, wide = S.wide and true or false })
end

local function startUpload(c, q)
    local dir = inside(q.dir)
    local name = safeName(q.name)
    if not dir or lfs.attributes(dir, "mode") ~= "directory" or not name then return fail(c, 400, "Bad folder or name") end
    local len = tonumber(c.headers["content-length"])
    if not len then return fail(c, 411, "Length required") end
    if len > MAX_UPLOAD then return fail(c, 413, "Too large") end
    -- room for it?
    local okU, u = pcall(function() return require("util").diskUsage(dir) end)
    if okU and u and u.available and len > u.available - 4 * 1024 * 1024 then return fail(c, 507, "Not enough room on the device") end
    -- the same name: "Name (2).epub"
    local path = dir .. "/" .. name
    if lfs.attributes(path, "mode") then
        local base, ext = name:match("^(.*)(%.[^.]+)$")
        base, ext = base or name, ext or ""
        for i = 2, 99 do
            local alt = string.format("%s (%d)%s", base, i, ext)
            if not lfs.attributes(dir .. "/" .. alt, "mode") then path, name = dir .. "/" .. alt, alt break end
        end
    end
    local f = io.open(path .. ".part", "wb")
    if not f then return fail(c, 500, "The file can't be written") end
    c.up = { f = f, path = path, name = name, left = len }
    c.state = "body"
    S.moving = S.moving + 1
    c.counted = true
    -- what came in with the head is the start of the file
    if #c.buf > 0 then
        local take = c.buf:sub(1, len)
        f:write(take)
        c.up.left = len - #take
        c.buf = ""
    end
end

local function finishUpload(c)
    local up = c.up
    up.f:close()
    c.up = nil
    local ok = os.rename(up.path .. ".part", up.path)
    if not ok then os.remove(up.path .. ".part") return fail(c, 500, "The file can't be saved") end
    json(c, 200, { ok = true, name = up.name })
    if S.on_received then pcall(S.on_received, up.path) end
end

local function delete(c, q)
    local path, rel = inside(q.path)
    if not path or rel == "" or rel == "/" or path == S.root then return fail(c, 400, "Bad path") end
    local mode = lfs.attributes(path, "mode")
    if mode == "file" then
        local ok = os.remove(path)
        if not ok then return fail(c, 500, "It can't be deleted") end
        -- its KOReader settings (reading position, highlights) go with it
        local sdr = path:gsub("%.[^./]+$", "") .. ".sdr"
        if lfs.attributes(sdr, "mode") == "directory" then pcall(function() require("ffi/util").purgeDir(sdr) end) end
    elseif mode == "directory" then
        local ok, err = lfs.rmdir(path)
        if not ok then return fail(c, 409, "Only an empty folder can be deleted") end
    else
        return fail(c, 404, "Not found")
    end
    json(c, 200, { ok = true })
    if S.on_change then pcall(S.on_change) end
end

local function mkdir(c, q)
    local dir = inside(q.dir)
    local name = safeName(q.name)
    if not dir or not name then return fail(c, 400, "Bad name") end
    local ok = lfs.mkdir(dir .. "/" .. name)
    if not ok then return fail(c, 409, "A folder of that name can't be made") end
    json(c, 200, { ok = true })
    if S.on_change then pcall(S.on_change) end
end

local function route(c)
    local method, target = c.method, c.target
    local path, query = target:match("^([^?]*)%??(.*)$")
    local q = parseQuery(query)
    -- the QR code's address: signed in, then the page
    if method == "GET" and path == "/" and q.k then
        if S.code and q.k == S.code then
            -- (the page itself, not a redirect: one request, nothing for a
            -- phone's browser to lose on the way; the page takes the code
            -- out of its address)
            return respond(c, 200, "text/html; charset=utf-8", page(), { COOKIE() })
        end
        return loginPage(c, true)
    end
    if method == "POST" and path == "/login" then
        c.want_form = true
        return
    end
    if not signedIn(c, q) then
        if path:match("^/api/") then return fail(c, 403, "Sign in first") end
        return loginPage(c, false)
    end
    if method == "GET" and (path == "/" or path == "/index.html") then
        return respond(c, 200, "text/html; charset=utf-8", page())
    elseif method == "GET" and path == "/api/list" then return list(c, q)
    elseif method == "POST" and path == "/api/upload" then return startUpload(c, q)
    elseif method == "GET" and path == "/api/file" then
        local p, rel = inside(q.path)
        if not p or lfs.attributes(p, "mode") ~= "file" then return fail(c, 404, "Not found") end
        return sendFile(c, p, rel:match("([^/]+)$") or "file")
    elseif method == "GET" and path == "/api/zip" then
        local p, rel = inside(q.path)
        if not p or lfs.attributes(p, "mode") ~= "directory" then return fail(c, 404, "No such folder") end
        local label = p:match("([^/]+)/*$") or "e-reader"
        return sendZip(c, p, label, q.hidden == "1")
    elseif method == "POST" and path == "/api/delete" then return delete(c, q)
    elseif method == "POST" and path == "/api/mkdir" then return mkdir(c, q)
    elseif method == "GET" and path == "/favicon.ico" then return respond(c, 404, "text/plain", "")
    end
    fail(c, 404, "Not found")
end

-- ---------------------------------------------------------------- connections

local function close(c)
    if c.closed then return end
    c.closed = true
    if c.up then
        pcall(function() c.up.f:close() end)
        os.remove(c.up.path .. ".part") -- an upload that didn't finish leaves nothing behind
        c.up = nil
    end
    if c.file_out then pcall(function() c.file_out:close() end) c.file_out = nil end
    if c.counted then S.moving = math.max(0, S.moving - 1) c.counted = false end
    pcall(function() c.sock:close() end)
end

--- The code typed into the sign-in page (once all of the form is here).
local function checkForm(c)
    if #c.buf < c.form_len then return end
    local f = parseQuery(c.buf)
    local code = (f.code or ""):gsub("%s", "")
    if S.code and code == S.code then
        respond(c, 302, "text/plain", "", { "Location: /", COOKIE() })
    else
        loginPage(c, true)
    end
end

local function parseHead(c)
    local stop = c.buf:find("\r\n\r\n", 1, true)
    if not stop then
        if #c.buf > MAX_HEAD then respond(c, 400, nil, "Bad request") end
        return
    end
    local head = c.buf:sub(1, stop - 1)
    c.buf = c.buf:sub(stop + 4)
    local first = head:match("^[^\r\n]+") or ""
    c.method, c.target = first:match("^(%u+)%s+(%S+)")
    if not c.method then return respond(c, 400, nil, "Bad request") end
    c.headers = {}
    for k, v in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do c.headers[k:lower()] = v end
    local ok, err = pcall(route, c)
    if not ok then
        logger.warn("ShelfTechUI: transfer:", err)
        respond(c, 500, nil, "Something went wrong")
    elseif c.want_form then
        c.state = "form"
        c.form_len = math.min(tonumber(c.headers["content-length"]) or 0, 4096)
        -- (a short form usually comes in the same packet as the head)
        checkForm(c)
    elseif c.state == "head" then
        respond(c, 500, nil, "No answer")
    end
end

--- One look at a connection: move what can be moved without waiting.
local function step(c)
    local moved = 0
    while moved < BUDGET and not c.closed do
        if c.state == "head" or c.state == "body" or c.state == "form" then
            local want = CHUNK
            if c.state == "body" then want = math.min(CHUNK, c.up.left) end
            if c.state == "body" and want <= 0 then finishUpload(c) break end
            local data, err, partial = c.sock:receive(want)
            data = data or partial
            if data and #data > 0 then
                c.seen = now()
                moved = moved + #data
                if c.state == "head" then
                    c.buf = c.buf .. data
                    -- a browser trying https first (a phone's often does):
                    -- hung up on at once, so it falls back to http without
                    -- waiting out its patience
                    if c.buf:byte(1) == 22 then close(c) break end
                    parseHead(c)
                elseif c.state == "body" then
                    local okW = c.up.f:write(data)
                    if not okW then fail(c, 507, "The device is full") close(c) return moved end
                    c.up.left = c.up.left - #data
                    if c.up.left <= 0 then finishUpload(c) end
                else -- form
                    c.buf = c.buf .. data
                    checkForm(c)
                end
            end
            if err == "closed" then close(c) break end
            if not data or #data == 0 or err == "timeout" then break end
        elseif c.state == "send" then
            if c.out_pos > #c.out then
                if c.more then
                    local chunk = c.more()
                    if chunk then c.out, c.out_pos = chunk, 1
                    else close(c) break end
                elseif c.file_out then
                    local chunk = c.file_out:read(CHUNK)
                    if chunk then c.out, c.out_pos = chunk, 1
                    else close(c) break end
                else
                    close(c) break
                end
            end
            local last, err, partial = c.sock:send(c.out, c.out_pos, math.min(#c.out, c.out_pos + CHUNK - 1))
            local sent_to = last or partial
            if sent_to and sent_to >= c.out_pos then
                moved = moved + (sent_to - c.out_pos + 1)
                c.out_pos = sent_to + 1
                c.seen = now()
            end
            if err == "closed" then close(c) break end
            if not last then break end -- (the socket's buffer is full: next look)
        else
            break
        end
    end
    if not c.closed and now() - c.seen > IDLE_TIMEOUT then close(c) end
    return moved
end

local function poll()
    if not S then return end
    -- new connections
    for _i = 1, 8 do
        local sock = S.server:accept()
        if not sock then break end
        sock:settimeout(0)
        pcall(function() sock:setoption("tcp-nodelay", true) end)
        S.conns[#S.conns + 1] = { sock = sock, state = "head", buf = "", seen = now() }
        -- who came (the Transfer page says so: if a phone's visit never
        -- shows there, it isn't reaching this device at all)
        local okP, peer = pcall(sock.getpeername, sock)
        if okP and peer and peer ~= S.visitor then
            S.visitor = peer
            if S.on_visit then pcall(S.on_visit, peer) end
        end
    end
    local moved = 0
    for k = #S.conns, 1, -1 do
        local c = S.conns[k]
        local ok, n = pcall(step, c)
        if not ok then
            logger.warn("ShelfTechUI: transfer connection:", n)
            close(c)
        else
            moved = moved + (n or 0)
        end
        if c.closed then table.remove(S.conns, k) end
    end
    if moved > 0 or #S.conns > 0 then S.last_activity = now() end
    -- while something is moving, look again at once (KOReader still gets
    -- its turn in between); otherwise a few times a second
    UIManager:scheduleIn((#S.conns > 0) and 0.01 or IDLE_EVERY, poll)
end

-- ---------------------------------------------------------------- on / off

function M.start(opts)
    if S then return S.port end
    local socket = require("socket")
    -- an IPv4 socket, asked for by name: a plain socket.tcp() takes its
    -- family from what "*" resolves to, which on some systems (and on some
    -- starts) is IPv6, and the bind fails with "Address family not supported"
    local server = (socket.tcp4 or socket.tcp)()
    server:setoption("reuseaddr", true)
    local ok, err = server:bind("0.0.0.0", opts.port)
    if not ok then
        server:close()
        return nil, err == "address already in use" and "busy" or tostring(err)
    end
    server:listen(16)
    server:settimeout(0)
    S = { server = server, port = opts.port, root = opts.root:gsub("/+$", ""), code = opts.code,
        wide = opts.code ~= nil,
        on_received = opts.on_received, on_change = opts.on_change, on_visit = opts.on_visit, device = opts.device,
        conns = {}, moving = 0, last_activity = now() }
    page_cache = nil
    UIManager:scheduleIn(IDLE_EVERY, poll)
    return opts.port
end

function M.stop()
    if not S then return end
    UIManager:unschedule(poll)
    for _i, c in ipairs(S.conns) do close(c) end
    pcall(function() S.server:close() end)
    S = nil
end

function M.running() return S and S.port or nil end
function M.busy() return S ~= nil and S.moving > 0 end
function M.lastActivity() return S and S.last_activity or 0 end

return M
