--[[
X-Ray, as on a Kindle: the people and places of the book you're reading,
each with what's known about them and every passage they appear in.

What's known is downloaded once per book (with Wi-Fi), from free sources:

  * Open Library: the book's main characters and places, by name.
  * Wikidata: its characters (and the names they also go by), a line on
    each, and their Wikipedia article.
  * Wikipedia: the start of each character's article.
  * A fan wiki, when Wikidata knows the book's (Dune, The Expanse…): the
    start of each character's page there. Fan wikis tell everything, so
    these stay folded away until asked for.

Then, on the device and offline, the book itself is searched for every name
(KOReader's own search, in a background process), which gives each one its
passages and where in the book they are. All of it is kept beside the book
(stui_xray.lua in its .sdr), so X-Ray opens at once after that, offline.

Opened from the dictionary's X-RAY key: on the looked-up word's entry when
it's a name X-Ray knows, else on the list.

  M.has(ui)                 is there an X-Ray for this book?
  M.open(ui, word)          the X-Ray (asks to download it when there's none)
  M.download(ui, done)      download and build it
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Look = require("bos_look")
local Page = require("bos_page")
local Screen = Device.screen
local S = Look.S

local M = {}

M.VERSION = 1
M.UA = "ShelfTechUI X-Ray for KOReader (https://github.com/Taiminator-OPDS/shelftechui.koplugin)"

--- Where each source is asked (a test points them all at a stand-in).
function M.endpoints()
    local mock = os.getenv("STUI_XRAY_MOCK")
    if mock then
        return { ol = mock .. "/ol", wd = mock .. "/wd", sparql = mock .. "/sparql", wp = mock .. "/wp", fandom = mock .. "/fandom/%s" }
    end
    return { ol = "https://openlibrary.org", wd = "https://www.wikidata.org", sparql = "https://query.wikidata.org/sparql",
        wp = "https://en.wikipedia.org", fandom = "https://%s.fandom.com" }
end

-- ---------------------------------------------------------------- the net (background only)

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function getJSON(url)
    local http = url:match("^https") and require("ssl.https") or require("socket.http")
    local socketutil = require("socketutil")
    local rapidjson = require("rapidjson")
    local sink = {}
    socketutil:set_timeout(8, 25)
    local _r, code = http.request{ url = url, method = "GET", sink = socketutil.table_sink(sink),
        headers = { ["User-Agent"] = M.UA, ["Accept"] = "application/json, application/sparql-results+json" } }
    socketutil:reset_timeout()
    if code ~= 200 then return nil, code end
    local ok, data = pcall(rapidjson.decode, table.concat(sink))
    return ok and data or nil
end

local function plainText(html)
    if type(html) ~= "string" then return nil end
    local s = html
    -- (infoboxes, tables, figures, references and the like: not prose)
    for _i, tag in ipairs({ "aside", "table", "figure", "style", "script", "sup", "div" }) do
        s = s:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. ">", " ")
    end
    s = s:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n"):gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&#(%d+);", function(n) local ok, c = pcall(require("util").unicodeCodepointToUtf8, tonumber(n)) return ok and c or "" end)
    s = s:gsub("[ \t]+", " "):gsub("\n%s*\n%s*\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end
M._plainText = plainText

--- The first `max` characters of `text`, at the end of a sentence.
local function firstSentences(text, max)
    if not text or #text <= max then return text end
    local cut = text:sub(1, max)
    local last = cut:match("^.*()[%.!?]%s")
    return last and cut:sub(1, last) or (cut .. "…")
end

local function norm(s) return (tostring(s or ""):lower():gsub("[%p]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end

--- The book on Wikidata: titles that match, then the one by this author.
local function findWork(E, title, author)
    local data = getJSON(E.wd .. "/w/api.php?action=wbsearchentities&format=json&language=en&type=item&limit=10&search=" .. urlencode(title))
    local ids = {}
    for _i, it in ipairs(data and data.search or {}) do ids[#ids + 1] = it.id end
    if #ids == 0 then return nil end
    local surname = norm(author):match("(%S+)$")
    local values = "wd:" .. table.concat(ids, " wd:")
    local q = "SELECT ?w ?al WHERE { VALUES ?w { " .. values .. " } ?w wdt:P50 ?a . ?a rdfs:label ?al . FILTER(LANG(?al) = \"en\") }"
    local res = getJSON(E.sparql .. "?format=json&query=" .. urlencode(q))
    local by = {}
    for _i, b in ipairs(res and res.results and res.results.bindings or {}) do
        local w = b.w and b.w.value and b.w.value:match("(Q%d+)$")
        if w and surname and norm(b.al and b.al.value):find(surname, 1, true) then by[w] = true end
    end
    for _i, id in ipairs(ids) do if by[id] then return id end end
    return nil
end

--- What's known about the book's people and places (here and now: only in
--- a background process). Returns { people = {…}, places = {…}, sources = {…} }.
function M.fetch(title, author)
    local E = M.endpoints()
    local out = { people = {}, places = {}, sources = {}, title = title, author = author }
    local seen = {}
    local function person(name)
        local k = norm(name)
        if k == "" then return nil end
        if not seen[k] then
            seen[k] = { name = name, names = { name } }
            table.insert(out.people, seen[k])
        end
        return seen[k]
    end
    -- Open Library: the names
    local surname = tostring(author or ""):match("(%S+)%s*$") or ""
    local s = getJSON(E.ol .. "/search.json?limit=5&fields=key,title,author_name&title=" .. urlencode(title)
        .. (surname ~= "" and ("&author=" .. urlencode(surname)) or ""))
    local key = s and s.docs and s.docs[1] and s.docs[1].key
    if key then
        local w = getJSON(E.ol .. key .. ".json")
        if w then
            table.insert(out.sources, "Open Library")
            local au = norm(author)
            for _i, n in ipairs(w.subject_people or {}) do
                n = tostring(n):gsub("%s*%(.-%)%s*$", "")
                -- (the author is filed among the people at times)
                if norm(n) ~= au and not (surname ~= "" and norm(n):find(norm(surname), 1, true) and norm(n):find(norm(tostring(author):match("^(%S+)") or ""), 1, true)) then
                    person(n)
                end
            end
            for _i, n in ipairs(w.subject_places or {}) do table.insert(out.places, { name = tostring(n), names = { tostring(n) } }) end
        end
    end
    -- Wikidata: the characters, what they're also called, their articles
    local qid = findWork(E, title, author or "")
    out.wikidata = qid
    local fandom
    if qid then
        local q = [[SELECT ?c ?cLabel ?cDescription ?article (GROUP_CONCAT(DISTINCT ?alt; separator="|") AS ?alts) WHERE {
  { wd:]] .. qid .. [[ wdt:P674 ?c } UNION { ?c wdt:P1441 wd:]] .. qid .. [[ }
  OPTIONAL { ?c skos:altLabel ?alt . FILTER(LANG(?alt) = "en") }
  OPTIONAL { ?article schema:about ?c ; schema:isPartOf <https://en.wikipedia.org/> }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
} GROUP BY ?c ?cLabel ?cDescription ?article LIMIT 120]]
        local r = getJSON(E.sparql .. "?format=json&query=" .. urlencode(q))
        local any = false
        for _i, b in ipairs(r and r.results and r.results.bindings or {}) do
            local label = b.cLabel and b.cLabel.value
            if label and not label:match("^Q%d+$") then
                any = true
                -- one entry per character: merged with Open Library's by name
                local p
                local alts = {}
                for a in tostring(b.alts and b.alts.value or ""):gmatch("[^|]+") do alts[#alts + 1] = a end
                for _j, n in ipairs({ label, unpack(alts) }) do p = p or seen[norm(n)] end
                p = p or person(label)
                p.name = label
                for _j, a in ipairs(alts) do
                    if not seen[norm(a)] then seen[norm(a)] = p table.insert(p.names, a) end
                end
                if not seen[norm(label)] then seen[norm(label)] = p end
                local has = false
                for _j, n in ipairs(p.names) do if n == label then has = true end end
                if not has then table.insert(p.names, 1, label) end
                p.short = b.cDescription and b.cDescription.value or p.short
                if b.article and b.article.value then
                    p.wp_title = b.article.value:match("/wiki/(.+)$")
                end
            end
        end
        if any then table.insert(out.sources, "Wikidata") end
        -- a fan wiki for the book, its series or its world
        local fq = "SELECT ?f WHERE { { wd:" .. qid .. " wdt:P4073 ?f } UNION { wd:" .. qid .. " wdt:P179 ?s . ?s wdt:P4073 ?f } UNION { wd:"
            .. qid .. " wdt:P1434 ?u . ?u wdt:P4073 ?f } } LIMIT 1"
        local fr = getJSON(E.sparql .. "?format=json&query=" .. urlencode(fq))
        local fb = fr and fr.results and fr.results.bindings and fr.results.bindings[1]
        fandom = fb and fb.f and fb.f.value
        out.fandom = fandom
    end
    -- Wikipedia: the start of each character's article
    local n = 0
    for _i, p in ipairs(out.people) do
        if p.wp_title and n < 40 then
            n = n + 1
            local sm = getJSON(E.wp .. "/api/rest_v1/page/summary/" .. p.wp_title)
            if sm and type(sm.extract) == "string" and sm.extract ~= "" then
                p.wiki = firstSentences(sm.extract, 900)
                p.wiki_title = sm.title
            end
        end
    end
    if n > 0 then table.insert(out.sources, "Wikipedia") end
    -- the fan wiki: the start of each character's page
    if fandom and fandom:match("^[%w%-%.]+$") then
        local base = string.format(E.fandom, fandom) .. "/api.php"
        local got = 0
        for _i, p in ipairs(out.people) do
            if got >= 30 then break end
            local sr = getJSON(base .. "?action=query&list=search&srlimit=1&format=json&formatversion=2&srsearch=" .. urlencode(p.name))
            local hit = sr and sr.query and sr.query.search and sr.query.search[1]
            if hit and hit.title then
                local pr = getJSON(base .. "?action=parse&prop=text&section=0&format=json&formatversion=2&page=" .. urlencode(hit.title))
                local text = plainText(pr and pr.parse and pr.parse.text)
                if text then
                    p.fan = firstSentences(text, 1200)
                    got = got + 1
                end
            end
        end
        if got > 0 then table.insert(out.sources, T("%1 fan wiki", fandom)) end
    end
    return out
end

-- ---------------------------------------------------------------- the book (background, with the document)

--- Every passage each name is in, from the book itself (a forked process
--- with the open document: KOReader's own full-text search).
function M.findMentions(doc, entries)
    for _i, e in ipairs(entries) do
        e.hits = {}
        local seen = {}
        local names = {}
        for _j, n in ipairs(e.names or { e.name }) do
            -- (very short or common words would find everything)
            if #n >= 3 then names[#names + 1] = n end
        end
        -- (the last word of a long name too, "Ahab" of "Captain Ahab", when
        -- no other entry has it)
        for _j, n in ipairs(e.extra or {}) do names[#names + 1] = n end
        for _j, n in ipairs(names) do
            local pattern = "\\b" .. n:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?\\|{}])", "\\%1") .. "\\b"
            local ok, res = pcall(doc.findAllText, doc, pattern, false, 9, 600, true)
            if not ok or not res then ok, res = pcall(doc.findAllText, doc, n, false, 9, 600, false) end
            for _k, h in ipairs(ok and res or {}) do
                local key = h.start
                -- (one passage for "Captain Ahab" and its "Ahab"; and none in
                -- links: a table of contents isn't a passage)
                local node, off = tostring(key):match("^(.-)%.(%d+)$")
                off = tonumber(off) or 0
                local near = false
                for _o, o in ipairs(node and seen[node] or {}) do if math.abs(o - off) < 24 then near = true end end
                if key and not near and not key:find("/a[/%[]") then
                    if node then seen[node] = seen[node] or {} table.insert(seen[node], off) end
                    local page
                    pcall(function() page = doc:getPageFromXPointer(h.start) end)
                    table.insert(e.hits, { xp = h.start, page = page,
                        text = ((h.prev_text or "") .. (h.matched_text or n) .. (h.next_text or "")):gsub("%s+", " ") })
                end
            end
        end
        table.sort(e.hits, function(a, b) return (a.page or 0) < (b.page or 0) end)
        e.count = #e.hits
    end
    return entries
end

--- The extra short names: the last word of a two- or three-word name, when
--- it's long enough and no other entry has it.
local function shortNames(entries)
    local owners = {}
    for _i, e in ipairs(entries) do
        for _j, n in ipairs(e.names) do
            local last = n:match("(%S+)$")
            if last and last ~= n and #last >= 4 and last:match("^%u") then
                owners[last] = owners[last] or {}
                owners[last][e] = true
            end
        end
    end
    for last, set in pairs(owners) do
        local count, only = 0, nil
        for e in pairs(set) do count = count + 1 only = e end
        if count == 1 then
            local have = false
            for _j, n in ipairs(only.names) do if n == last then have = true end end
            if not have then only.extra = only.extra or {} table.insert(only.extra, last) end
        end
    end
end

-- ---------------------------------------------------------------- keeping it

local function path(ui)
    local file = ui and ui.document and ui.document.file
    if not file then return nil end
    local ok, dir = pcall(function() return require("docsettings"):getSidecarDir(file) end)
    if not ok or not dir then return nil end
    return dir .. "/stui_xray.lua"
end

function M.load(ui)
    local p = path(ui)
    if not p then return nil end
    M._cache = M._cache or {}
    if M._cache[p] then return M._cache[p] end
    local ok, data = pcall(dofile, p)
    if ok and type(data) == "table" and data.version == M.VERSION then
        M._cache[p] = data
        return data
    end
end

function M.has(ui) return M.load(ui) ~= nil end

function M.save(ui, data)
    local p = path(ui)
    if not p then return false end
    local lfs = require("libs/libkoreader-lfs")
    lfs.mkdir((p:gsub("/[^/]*$", "")))
    local dump = require("dump")
    local f = io.open(p .. ".tmp", "w")
    if not f then return false end
    f:write("-- ShelfTechUI X-Ray\nreturn ", dump(data), "\n")
    f:close()
    os.rename(p .. ".tmp", p)
    M._cache = M._cache or {}
    M._cache[p] = data
    return true
end

function M.remove(ui)
    local p = path(ui)
    if p then os.remove(p) if M._cache then M._cache[p] = nil end end
end

-- ---------------------------------------------------------------- downloading

local function notify(text) pcall(function() require("ui/widget/notification"):notify(text) end) end

--- Download what's known and find it in the book; done(data | nil, why).
function M.download(ui, done)
    local props = ui.doc_props or {}
    local title = props.display_title or props.title or ""
    local author = (props.authors or ""):gsub("\n.*", "")
    title = title:gsub("%s*[:;%(].*$", "")
    if title == "" then return done(nil, _("This book has no title to look for.")) end
    local Async = require("bos_store").Async
    local msg = require("ui/widget/infomessage"):new{ text = _("X-Ray: asking Open Library, Wikidata and Wikipedia…") }
    UIManager:show(msg)
    Async.run(function() return M.fetch(title, author) end, function(ok, data)
        if not ok or type(data) ~= "table" then
            UIManager:close(msg)
            return done(nil, _("X-Ray: the sources couldn't be reached. Check the Wi-Fi."))
        end
        if #data.people == 0 and #data.places == 0 then
            UIManager:close(msg)
            return done(nil, T(_("No X-Ray is known for “%1”: Open Library and Wikidata list no characters for it."), title))
        end
        UIManager:close(msg)
        local msg2 = require("ui/widget/infomessage"):new{ text = _("X-Ray: finding them in the book…") }
        UIManager:show(msg2)
        shortNames(data.people)
        local doc = ui.document
        Async.run(function()
            return M.findMentions(doc, data.people), M.findMentions(doc, data.places)
        end, function(ok2, people, places)
            UIManager:close(msg2)
            if not ok2 or type(people) ~= "table" then return done(nil, _("X-Ray: the book couldn't be searched.")) end
            -- (only who's in this book; the most mentioned first)
            local function keep(list)
                local out = {}
                for _i, e in ipairs(list) do if (e.count or 0) > 0 then out[#out + 1] = e end end
                table.sort(out, function(a, b) return a.count > b.count end)
                return out
            end
            data.people, data.places = keep(people), keep(places or {})
            data.version, data.at = M.VERSION, os.time()
            if #data.people == 0 and #data.places == 0 then
                return done(nil, _("X-Ray: none of the names found for this book appear in it."))
            end
            M.save(ui, data)
            done(data)
        end, 600)
    end, 120)
end

-- ---------------------------------------------------------------- the pages

local function spoilerFree() return require("bos_settings_store").get("xray_spoiler_free") ~= false end

--- The passages to show: up to where you are, when spoiler-free.
local function visibleHits(ui, e)
    if not spoilerFree() then return e.hits or {} end
    local cur = ui.getCurrentPage and ui:getCurrentPage() or (ui.document and ui.document:getCurrentPage()) or math.huge
    local out = {}
    for _i, h in ipairs(e.hits or {}) do
        local pg = h.page
        pcall(function() if h.xp and ui.document.getPageFromXPointer then pg = ui.document:getPageFromXPointer(h.xp) end end)
        if (pg or 0) <= cur then out[#out + 1] = { xp = h.xp, page = pg, text = h.text } end
    end
    return out
end

--- Where the mentions are, across the book: a strip.
local function strip(bb, ui, e, x, y, w, h)
    local total = 1
    pcall(function() total = ui.document:getPageCount() end)
    local cur
    pcall(function() cur = ui:getCurrentPage() end)
    bb:paintRect(x, y + math.floor(h / 2), w, math.max(1, S(1)), Look.LIGHT)
    for _i, hit in ipairs(e.hits or {}) do
        local px = x + math.floor((math.max(1, hit.page or 1) - 1) / math.max(1, total - 1) * (w - 2))
        local hidden = spoilerFree() and cur and (hit.page or 0) > cur
        bb:paintRect(px, y, math.max(2, S(2)), h, hidden and Look.LIGHT or Look.INK)
    end
    if cur then
        local cx = x + math.floor((cur - 1) / math.max(1, total - 1) * (w - 2))
        bb:paintRect(cx, y - S(3), math.max(1, S(1)), h + S(6), Look.GRAY)
    end
end

local function jump(ui, hit)
    pcall(function() ui.link:addCurrentLocationToStack() end)
    if ui.rolling and hit.xp then
        ui.rolling:onGotoXPointer(hit.xp, hit.xp)
    elseif hit.page then
        ui:handleEvent(require("ui/event"):new("GotoPage", hit.page))
    end
end

--- One entry: what's known, then its passages.
function M.openEntry(ui, e, kind, on_jump)
    local o = { pg = 1, fan_shown = false }
    local page
    page = Page:new{ caption = _("X-Ray"),
        draw = function(self, bb, y, w)
            local x = self.pad
            local H = Screen:getHeight()
            y = y + Page.wrap(bb, e.name, Look.serif(22, true), x, y, w, 2, S(30)) + S(2)
            local sub = {}
            if e.short then sub[#sub + 1] = e.short end
            sub[#sub + 1] = T(e.count == 1 and _("%1 mention") or _("%1 mentions"), e.count or 0)
            y = y + Page.wrap(bb, table.concat(sub, "  ·  "), Look.serif(13, false, true), x, y, w, 2, S(20), Look.GRAY) + S(10)
            strip(bb, ui, e, x, y, w - Look.SHADOW_SMALL, S(14))
            y = y + S(28)
            if o.pg == 1 then
                local room = H - y - S(260)
                if e.wiki then
                    Page.heading(bb, _("Wikipedia"), x, y, w)
                    y = y + S(30)
                    local lines = math.max(3, math.floor(math.min(room, S(260)) / S(22)))
                    y = y + Page.wrap(bb, e.wiki, Look.serif(14), x, y, w, lines, S(22)) + S(12)
                end
                if e.fan then
                    Page.heading(bb, _("Fan wiki"), x, y, w, o.fan_shown and nil or _("May spoil"))
                    y = y + S(30)
                    if o.fan_shown then
                        y = y + Page.wrap(bb, e.fan, Look.serif(14), x, y, w, math.max(3, math.floor((H - y - S(200)) / S(22))), S(22)) + S(12)
                    else
                        local r = Look.button(bb, x, y, S(220), S(38), _("Show what it says"), { size = 11 })
                        self:hit(r, function() o.fan_shown = true self:refresh("ui") end)
                        y = y + S(52)
                    end
                end
                if not e.wiki and not e.fan then
                    -- (nothing written about it: its first appearance says who it is)
                    local first = e.hits and e.hits[1]
                    if first then
                        Page.heading(bb, _("First appears"), x, y, w, first.page and T(_("page %1"), first.page) or nil)
                        y = y + S(30)
                        y = y + Page.wrap(bb, "…" .. first.text .. "…", Look.serif(14, false, true), x, y, w, 4, S(22)) + S(12)
                    end
                end
            end
            -- the passages
            local hits = visibleHits(ui, e)
            local hidden = (e.count or 0) - #hits
            Page.heading(bb, _("Passages"), x, y, w, hidden > 0 and T(_("%1 later on, hidden"), hidden) or nil)
            y = y + S(30)
            local rh = S(70)
            local per = math.max(1, math.floor((H - y - S(60)) / rh))
            local pages = math.max(1, math.ceil(#hits / per))
            o.pages = pages
            o.hpg = math.max(1, math.min(o.hpg or 1, pages))
            if #hits == 0 then
                Page.wrap(bb, _("Not yet: it comes later in the book (spoiler-free is on: ⋯ to change it)."), Look.serif(14, false, true), x, y, w, 3, S(22), Look.GRAY)
            end
            for k = 1, per do
                local h = hits[(o.hpg - 1) * per + k]
                if not h then break end
                local ry = y + (k - 1) * rh
                Look.label(bb, h.page and T(_("p. %1"), h.page) or "", x, ry, S(70), S(20), 10, { color = Look.GRAY })
                Page.wrap(bb, "…" .. h.text .. "…", Look.serif(13), x + S(76), ry, w - S(76), 2, S(21))
                self:hit(Geom:new{ x = x, y = ry - S(4), w = w, h = rh - S(4) }, function()
                    if on_jump then on_jump() end
                    self:onClose()
                    jump(ui, h)
                end)
                if k < per and hits[(o.hpg - 1) * per + k + 1] then bb:paintRect(x, ry + rh - S(8), w, 1, Look.LIGHT) end
            end
            if pages > 1 then
                local fy = H - S(52)
                local kw = S(56)
                local rp = Look.button(bb, x, fy, kw, S(38), "\u{2039}", { size = 15, enabled = o.hpg > 1 })
                if o.hpg > 1 then self:hit(rp, function() o.hpg = o.hpg - 1 self:refresh("ui") end) end
                local rn = Look.button(bb, x + w - kw - Look.SHADOW_SMALL, fy, kw, S(38), "\u{203A}", { size = 15, enabled = o.hpg < pages })
                if o.hpg < pages then self:hit(rn, function() o.hpg = o.hpg + 1 self:refresh("ui") end) end
                Look.label(bb, T(_("%1 / %2"), o.hpg, pages), x + kw, fy, w - 2 * kw, S(38), 12, { align = "center" })
            end
        end,
        on_swipe = function(self, dir)
            if dir == "west" and (o.hpg or 1) < (o.pages or 1) then o.hpg = o.hpg + 1 self:refresh("ui")
            elseif dir == "east" then
                if (o.hpg or 1) > 1 then o.hpg = o.hpg - 1 self:refresh("ui") else self:onClose() end
            end
        end,
        on_more = function(self, rect) M.more(ui, self, rect) end,
    }
    page:show()
    return page
end

function M.more(ui, page, rect)
    require("bos_ui").openList({
        { text = spoilerFree() and _("Spoiler-free: on (only what you've read)") or _("Spoiler-free: off (the whole book)"),
          callback = function()
              require("bos_settings_store").set("xray_spoiler_free", not spoilerFree())
              page:refresh("ui")
          end },
        { text = _("Download it again"), callback = function()
              page:onClose()
              if M.list then pcall(function() M.list:onClose() end) end
              M.remove(ui)
              M.open(ui)
          end },
        { text = _("Remove this X-Ray"), callback = function()
              page:onClose()
              if M.list then pcall(function() M.list:onClose() end) end
              M.remove(ui)
              notify(_("X-Ray removed"))
          end },
    }, rect)
end

--- The list: People and Places, the most mentioned first.
function M.openList(ui, data, on_jump)
    local o = { tab = #data.people > 0 and "people" or "places", pg = {} }
    local list
    list = Page:new{ caption = _("X-Ray"),
        draw = function(self, bb, y, w)
            local x = self.pad
            local H = Screen:getHeight()
            y = y + Page.wrap(bb, data.title or "", Look.serif(18, true), x, y, w, 1, S(26)) + S(2)
            Look.label(bb, T(_("From %1"), table.concat(data.sources or {}, ", ")), x, y, w, S(18), 9, { color = Look.GRAY, keep_case = true })
            y = y + S(28)
            local cells = { { key = "people", text = T(_("People %1"), #data.people) }, { key = "places", text = T(_("Places %1"), #data.places) } }
            local segs = Look.segments(bb, x, y, w - Look.SHADOW_SMALL, S(36), cells, o.tab, { size = 11, shadow = Look.SHADOW_SMALL })
            for key, r in pairs(segs) do self:hit(r, function() o.tab = key self:refresh("ui") end) end
            y = y + S(36) + Look.SHADOW_SMALL + S(14)
            local items = data[o.tab] or {}
            local rh = S(72)
            local per = math.max(1, math.floor((H - y - S(60)) / rh))
            local pages = math.max(1, math.ceil(#items / per))
            o.pages = pages
            local cur = math.max(1, math.min(o.pg[o.tab] or 1, pages))
            o.pg[o.tab] = cur
            if #items == 0 then
                Page.wrap(bb, _("None found in this book."), Look.serif(15, false, true), x, y, w, 2, S(23), Look.GRAY)
            end
            for k = 1, per do
                local e = items[(cur - 1) * per + k]
                if not e then break end
                local ry = y + (k - 1) * rh
                Page.wrap(bb, e.name, Look.text and Look.text(15, true) or Look.serif(15, true), x, ry, w - S(90), 1, S(22))
                Look.label(bb, tostring(e.count or 0), x + w - S(80), ry, S(70), S(22), 11, { align = "right", color = Look.GRAY })
                if e.short then Page.wrap(bb, e.short, Look.serif(12, false, true), x, ry + S(24), w - S(10), 1, S(18), Look.GRAY) end
                strip(bb, ui, e, x, ry + S(48), w - Look.SHADOW_SMALL, S(10))
                self:hit(Geom:new{ x = x, y = ry - S(4), w = w, h = rh - S(4) }, function() M.openEntry(ui, e, o.tab, on_jump) end)
            end
            if pages > 1 then
                local fy = H - S(52)
                local kw = S(56)
                local rp = Look.button(bb, x, fy, kw, S(38), "\u{2039}", { size = 15, enabled = cur > 1 })
                if cur > 1 then self:hit(rp, function() o.pg[o.tab] = cur - 1 self:refresh("ui") end) end
                local rn = Look.button(bb, x + w - kw - Look.SHADOW_SMALL, fy, kw, S(38), "\u{203A}", { size = 15, enabled = cur < pages })
                if cur < pages then self:hit(rn, function() o.pg[o.tab] = cur + 1 self:refresh("ui") end) end
                Look.label(bb, T(_("%1 / %2"), cur, pages), x + kw, fy, w - 2 * kw, S(38), 12, { align = "center" })
            end
        end,
        on_swipe = function(self, dir)
            local cur = o.pg[o.tab] or 1
            if dir == "west" and cur < (o.pages or 1) then o.pg[o.tab] = cur + 1 self:refresh("ui")
            elseif dir == "east" then
                if cur > 1 then o.pg[o.tab] = cur - 1 self:refresh("ui") else self:onClose() end
            end
        end,
        on_more = function(self, rect) M.more(ui, self, rect) end,
        on_close = function() M.list = nil end,
    }
    M.list = list
    list:show()
    return list
end

--- The entry for `word`, if it's one of the names.
function M.find(data, word)
    local w = norm(word)
    if w == "" then return nil end
    for _i, kind in ipairs({ "people", "places" }) do
        for _j, e in ipairs(data[kind] or {}) do
            for _k, n in ipairs(e.names or {}) do
                local nn = norm(n)
                if nn == w or (" " .. nn .. " "):find(" " .. w .. " ", 1, true) then return e, kind end
            end
            for _k, n in ipairs(e.extra or {}) do if norm(n) == w then return e, kind end end
        end
    end
end

--- X-Ray for the book that's open, on `word`'s entry when it's a name.
--- With none yet: asks, then downloads it (Wi-Fi once).
function M.open(ui, word, on_jump)
    if not (ui and ui.document) then return end
    local data = M.load(ui)
    if data then
        local e, kind = M.find(data, word)
        if e then return M.openEntry(ui, e, kind, on_jump) end
        return M.openList(ui, data, on_jump)
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Download X-Ray for this book?\n\nIts people and places, with what Open Library, Wikidata and Wikipedia know about them (and a fan wiki, if the book has one), are downloaded once; then every passage they're in is found in the book. After that it works without Wi-Fi."),
        ok_text = _("Download"),
        ok_callback = function()
            require("ui/network/manager"):runWhenOnline(function()
                M.download(ui, function(got, why)
                    if not got then
                        UIManager:show(require("ui/widget/infomessage"):new{ text = why or _("X-Ray couldn't be made."), timeout = 6 })
                        return
                    end
                    notify(T(_("X-Ray ready: %1 people, %2 places"), #got.people, #got.places))
                    local e, kind = M.find(got, word)
                    if e then M.openEntry(ui, e, kind, on_jump) else M.openList(ui, got, on_jump) end
                end)
            end)
        end,
    })
end

return M
