--[[
Wrapped's sharing: your year on a phone, by a QR code.

  M.text(r)            the year as a few lines of text (the Text QR: needs
                       nothing, the phone reads the text straight from it)
  M.start(files, r)    a small web server for the cards' pictures
                       ({ { name, path }, … }), on this Wi-Fi only, at a link
                       with a random part nobody can guess; returns the link
                       (nil without Wi-Fi). The page shows every card in
                       order (hold one to save or share it), Save all, and
                       the text with a Copy key. It stops by itself after 10
                       minutes, and when Wrapped closes.
  M.stop()
  M.state              { url, opened = phones that opened the page }

Nothing leaves this Wi-Fi: the phone fetches the picture from the device.
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = { state = {} }

local LIFETIME = 10 * 60
local PORTS = { 8090, 8091, 8092, 8093, 8094, 8095 }

local function hours(secs)
    local h = secs / 3600
    if h >= 10 then return tostring(math.floor(h + 0.5)) end
    return string.format("%.1f", h)
end

function M.text(r)
    local lines = { T(_("My %1 in books"), r.year), "" }
    table.insert(lines, T(_("%1 hours of reading"), hours(r.secs or 0)))
    table.insert(lines, T(#r.finished == 1 and _("%1 book finished") or _("%1 books finished"), #r.finished))
    if r.top and r.top.title then
        table.insert(lines, r.top.author and T(_("Book of the year: %1, by %2"), r.top.title, r.top.author)
            or T(_("Book of the year: %1"), r.top.title))
    end
    if r.authors and r.authors[1] then table.insert(lines, T(_("Top author: %1"), r.authors[1].name)) end
    if r.streak and r.streak.n > 1 then table.insert(lines, T(_("Longest streak: %1 days"), r.streak.n)) end
    if r.long_haul and r.long_haul[1] then
        local b = r.long_haul[1]
        table.insert(lines, T(_("The long haul: %1, %2 days"), b.title, b.days))
    end
    if r.persona then table.insert(lines, T(_("I'm %1."), r.persona.name)) end
    table.insert(lines, "")
    table.insert(lines, _("Wrapped with ShelfTechUI for KOReader"))
    return table.concat(lines, "\n")
end

local function esc(s)
    return (tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function page(r, text, files)
    local imgs, names = {}, {}
    for i, f in ipairs(files) do
        table.insert(imgs, '<figure><img src="' .. esc(f.name) .. '" alt="' .. esc(T(_("Card %1"), i)) .. '" loading="lazy">'
            .. '<a class="w" href="' .. esc(f.name) .. '" download="wrapped-' .. r.year .. '-' .. esc(f.name) .. '">'
            .. esc(T(_("Save card %1"), i)) .. "</a></figure>")
        table.insert(names, '"' .. f.name .. '"')
    end
    return table.concat({
        '<!doctype html><html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1">',
        "<title>", esc(T(_("My %1 in books"), r.year)), "</title>",
        "<style>body{margin:0;background:#fff;color:#000;font:16px/1.5 ui-monospace,Menlo,monospace}",
        "main{max-width:560px;margin:0 auto;padding:16px}h1{font-size:18px;text-transform:uppercase;margin:8px 0 12px}",
        "img{width:100%;height:auto;border:2px solid #000;box-sizing:border-box;-webkit-touch-callout:default}",
        "p{margin:10px 0;color:#444;font-size:14px}textarea{width:100%;box-sizing:border-box;height:12em;",
        "font:inherit;border:2px solid #000;padding:8px;resize:vertical}",
        "a,button{display:inline-block;border:2px solid #000;background:#000;color:#fff;font:inherit;",
        "text-transform:uppercase;font-size:14px;padding:10px 16px;margin:6px 8px 6px 0;text-decoration:none;cursor:pointer}",
        "a.w{background:#fff;color:#000}figure{margin:0 0 22px}</style></head><body><main>",
        "<h1>", esc(T(_("My %1 in books"), r.year)), "</h1>",
        "<p>", esc(T(_("%1 cards. Hold one to save or share it, or save them all."), #files)), "</p>",
        '<button id="all">', esc(_("Save all")), "</button>",
        table.concat(imgs),
        '<textarea id="t" readonly>', esc(text), "</textarea>",
        '<button id="c">', esc(_("Copy the text")), "</button>",
        "<script>document.getElementById('c').onclick=function(){var t=document.getElementById('t');",
        "t.select();t.setSelectionRange(0,99999);try{document.execCommand('copy');this.textContent='",
        esc(_("Copied")), "'}catch(e){}};",
        "document.getElementById('all').onclick=function(){var n=[", table.concat(names, ","), "],i=0;",
        "(function next(){if(i>=n.length)return;var a=document.createElement('a');a.href=n[i];",
        "a.download='wrapped-", r.year, "-'+n[i];document.body.appendChild(a);a.click();a.remove();i++;setTimeout(next,600)})()};",
        "</script></main></body></html>",
    })
end

--- This device's address on the Wi-Fi (nil when not connected).
function M.ip()
    local ok, info = pcall(function() return Device.retrieveNetworkInfo and Device:retrieveNetworkInfo() end)
    if not ok or not info then return nil end
    local ip
    if type(info) == "table" then ip = info.ip else ip = tostring(info):match("(%d+%.%d+%.%d+%.%d+)") end
    if ip == "127.0.0.1" then return nil end
    return ip
end

local function firewall(port, open)
    if not Device:isKindle() then return end
    local flag = open and "-A" or "-D"
    os.execute(string.format("iptables %s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null", flag, port))
    os.execute(string.format("iptables %s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null", flag, port))
end

local function token()
    local chars = "abcdefghjkmnpqrstuvwxyz23456789"
    local t = {}
    math.randomseed(os.time() + math.floor(os.clock() * 1e6))
    for i = 1, 8 do local k = math.random(#chars) t[i] = chars:sub(k, k) end
    return table.concat(t)
end

local function reply(c, status, ctype, body)
    c:send(table.concat({ "HTTP/1.0 ", status, "\r\nContent-Type: ", ctype, "\r\nContent-Length: ", #body,
        "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" }))
    local i = 1
    while i <= #body do
        local last, err, partial = c:send(body, i, math.min(#body, i + 65535))
        if not last then
            if err == "timeout" and partial and partial >= i then i = partial + 1 else break end
        else
            i = last + 1
        end
    end
end

local function serve(c)
    local s = M.state
    c:settimeout(3)
    local line = c:receive("*l")
    if not line then return end
    repeat local h = c:receive("*l") until not h or h == ""
    local path = line:match("^GET (%S+)") or ""
    path = path:gsub("%?.*$", "")
    local base = "/" .. s.token .. "/"
    if path == "/" .. s.token then
        reply(c, "301 Moved Permanently\r\nLocation: " .. base, "text/plain", "")
    elseif path == base or path == base .. "index.html" then
        s.opened = (s.opened or 0) + 1
        reply(c, "200 OK", "text/html; charset=utf-8", s.html)
        if s.on_open then pcall(s.on_open) end
    elseif s.files[path:sub(#base + 1)] then
        reply(c, "200 OK", "image/png", s.files[path:sub(#base + 1)])
    else
        reply(c, "404 Not Found", "text/plain", "Not found")
    end
end

local function poll()
    local s = M.state
    if not s.server then return end
    if os.time() >= s.until_t then M.stop() if s.on_open then pcall(s.on_open) end return end
    for _i = 1, 4 do
        local c = s.server:accept()
        if not c then break end
        local ok, err = pcall(serve, c)
        if not ok then logger.warn("ShelfTechUI: Wrapped share:", err) end
        pcall(function() c:close() end)
    end
    UIManager:scheduleIn(0.25, poll)
end

--- Serve the cards' pictures (with r's text); returns the link, or nil and
--- why.
function M.start(list, r, on_open)
    local ip = M.ip()
    if not ip then return nil, "wifi" end
    local s = M.state
    local files, served = {}, {}
    for _i, f in ipairs(list) do
        local fh = io.open(f.path, "rb")
        if fh then
            files[f.name] = fh:read("*a")
            fh:close()
            table.insert(served, f)
        end
    end
    if #served == 0 then return nil, "picture" end
    local html = page(r, M.text(r), served)
    if s.server then
        -- already on: the new pictures and text, same link
        s.files, s.html, s.on_open, s.until_t = files, html, on_open, os.time() + LIFETIME
        s.url = T("http://%1:%2/%3/", ip, s.port, s.token)
        return s.url
    end
    local socket = require("socket")
    local server, port
    for _i, p in ipairs(PORTS) do
        local srv = socket.tcp()
        srv:setoption("reuseaddr", true)
        if srv:bind("*", p) and srv:listen(8) then server, port = srv, p break end
        srv:close()
    end
    if not server then return nil, "port" end
    server:settimeout(0)
    firewall(port, true)
    M.state = { server = server, port = port, token = token(), files = files, html = html,
        until_t = os.time() + LIFETIME, opened = 0, on_open = on_open }
    M.state.url = T("http://%1:%2/%3/", ip, port, M.state.token)
    UIManager:scheduleIn(0.25, poll)
    return M.state.url
end

function M.stop()
    local s = M.state
    if s.server then
        pcall(function() s.server:close() end)
        firewall(s.port, false)
    end
    UIManager:unschedule(poll)
    M.state = { opened = s.opened }
end

function M.running() return M.state.server ~= nil end

function M.minutesLeft()
    local s = M.state
    if not s.server then return 0 end
    return math.max(1, math.ceil((s.until_t - os.time()) / 60))
end

return M
