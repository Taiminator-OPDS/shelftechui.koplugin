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

From the dictionary's X-Ray key: a pop-up for the looked-up name (who it
is, where it's mentioned; keys for its passages and everyone). From the
reader menu's X-Ray key: the whole X-Ray, people and places. When the book isn't found by its
own title and author, the closest matches (Open Library's works, Wikidata's
books) are listed to choose from, with a search of your own.

  M.has(ui)                 is there an X-Ray for this book?
  M.open(ui, word)          the X-Ray (asks to download it when there's none)
  M.download(ui, done)      download and build it
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local ConfirmBox = require("ui/widget/confirmbox")
local askDownload

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

M._net = { calls = 0, failed = 0 }
local function getJSON(url, depth, retry)
    local http = url:match("^https") and require("ssl.https") or require("socket.http")
    local socketutil = require("socketutil")
    local rapidjson = require("rapidjson")
    local sink = {}
    socketutil:set_timeout(6, 15)
    local _r, code, headers = http.request{ url = url, method = "GET", sink = socketutil.table_sink(sink),
        headers = { ["User-Agent"] = M.UA, ["Accept"] = "application/json, application/sparql-results+json" } }
    socketutil:reset_timeout()
    M._net.calls = M._net.calls + 1
    if (code == 301 or code == 302 or code == 307 or code == 308) and headers and headers.location and (depth or 0) < 2 then
        M._net.calls = M._net.calls - 1
        local loc = headers.location
        if loc:sub(1, 1) == "/" then loc = url:match("^(https?://[^/]+)") .. loc end
        return getJSON(loc, (depth or 0) + 1)
    end
    if code ~= 200 and retry and type(code) == "string" then
        -- (Open Library drops connections now and then: once more)
        M._net.calls = M._net.calls - 1
        return getJSON(url, depth, false)
    end
    if code ~= 200 then
        M._net.failed = M._net.failed + 1
        require("logger").info("ShelfTechUI: X-Ray:", code, (url:gsub("query=.*", "query=…")))
        return nil, code
    end
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

--- "Melville, Herman" → "Herman Melville"; the first author only.
function M.authorName(a)
    a = tostring(a or ""):gsub("\n.*", ""):gsub("%s*[&;].*$", "")
    local last, first = a:match("^([^,]+),%s*(.+)$")
    if last then a = first .. " " .. last end
    return (a:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- The book's title without its subtitle ("Moby Dick; Or, The Whale" →
--- "Moby Dick").
function M.shortTitle(t)
    t = tostring(t or ""):gsub("%s*[:;%(%[].*$", ""):gsub(",%s*[Oo]r,?%s.*$", ""):gsub("%s+[Oo]r,%s.*$", "")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Books with that name, to choose from (background only): Open Library's
--- works and Wikidata's items, best first.
function M.candidates(query, author)
    local E = M.endpoints()
    M._net = { calls = 0, failed = 0 }
    local out = {}
    local s = getJSON(E.ol .. "/search.json?limit=8&fields=key,title,author_name,first_publish_year,edition_count&q=" .. urlencode(query))
    for _i, d in ipairs(s and s.docs or {}) do
        if d.key and d.title then
            local au = type(d.author_name) == "table" and d.author_name[1] or nil
            table.insert(out, { ol = d.key, title = d.title, author = au, year = d.first_publish_year,
                editions = d.edition_count, from = "Open Library" })
        end
    end
    local w = getJSON(E.wd .. "/w/api.php?action=wbsearchentities&format=json&language=en&type=item&limit=10&search=" .. urlencode(query))
    for _i, it in ipairs(w and w.search or {}) do
        local desc = it.description or ""
        -- (books, plays, series, films of books…: not people or places)
        local d = desc:lower()
        if d:find("novel") or d:find("book") or d:find("literary") or d:find("story") or d:find("play by")
            or d:find("poem") or d:find("series") or d:find("saga") or d:find("trilogy") or d:find("work by") or d:find("fiction") then
            table.insert(out, { qid = it.id, title = it.label or query, desc = desc, from = "Wikidata" })
        end
    end
    -- by this author first, then the most printed
    local sur = norm(author):match("(%S+)$")
    local function score(c)
        local v = 0
        if sur and (norm(c.author):find(sur, 1, true) or norm(c.desc):find(sur, 1, true)) then v = v + 1000 end
        if norm(c.title) == norm(query) then v = v + 100 end
        return v + math.min(99, c.editions or (c.qid and 50) or 0)
    end
    for i, c in ipairs(out) do c.i = i c.score = score(c) end
    table.sort(out, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.i < b.i end)
    return out, (M._net.calls > 0 and M._net.failed == M._net.calls)
end

--- Open Library's names for the book's people and places (background only):
--- { people = { names }, places = { names }, found = bool, offline = bool }.
--- `pick` (from M.candidates): that Open Library work, or a Wikidata item's
--- title to look for.
function M.fetchOL(title, author, pick)
    local E = M.endpoints()
    M._net = { calls = 0, failed = 0 }
    pick = pick or {}
    author = M.authorName(author)
    local out = { people = {}, places = {} }
    local surname = author:match("(%S+)%s*$") or ""
    local first = author:match("^(%S+)") or ""
    local function readWork(key)
        local w = getJSON(E.ol .. key .. ".json", 0, true)
        if not (w and (w.subject_people or w.subject_places)) then return false end
        local au = norm(author)
        for _i, n in ipairs(w.subject_people or {}) do
            n = tostring(n):gsub("%s*%(.-%)%s*$", "")
            -- (the author is filed among the people at times)
            local nn = norm(n)
            if nn ~= au and not (surname ~= "" and nn:find(norm(surname), 1, true) and nn:find(norm(first), 1, true)) then
                table.insert(out.people, n)
            end
        end
        for _i, n in ipairs(w.subject_places or {}) do table.insert(out.places, tostring(n)) end
        out.found = true
        return true
    end
    if pick.ol then
        readWork(pick.ol)
    else
        if pick.qid and pick.title then title = M.shortTitle(pick.title) end
        -- (the first of its matches that lists anyone)
        local queries = { "title=" .. urlencode(title) .. (surname ~= "" and ("&author=" .. urlencode(surname)) or ""),
            "q=" .. urlencode(title .. " " .. surname) }
        local tried = {}
        for _q, qs in ipairs(queries) do
            local s = getJSON(E.ol .. "/search.json?limit=5&fields=key,title,author_name&" .. qs, 0, true)
            local n = 0
            for _i, d in ipairs(s and s.docs or {}) do
                if d.key and not tried[d.key] and n < 3 then
                    tried[d.key] = true
                    n = n + 1
                    if readWork(d.key) then break end
                end
            end
            if out.found then break end
        end
    end
    out.offline = M._net.calls > 0 and M._net.failed == M._net.calls
    return out
end

--- Wikidata's characters for the book (background only): { qid, chars =
--- { { label, desc, alts, wp } }, fandom, offline }.
function M.fetchWD(title, author, pick)
    local E = M.endpoints()
    M._net = { calls = 0, failed = 0 }
    pick = pick or {}
    author = M.authorName(author)
    local out = { chars = {} }
    local qid = pick.qid
    if not qid then qid = findWork(E, pick.ol and M.shortTitle(pick.title or title) or title, pick.author or author) end
    out.qid = qid
    if qid then
        local q = [[SELECT ?c ?cLabel ?cDescription ?article (GROUP_CONCAT(DISTINCT ?alt; separator="|") AS ?alts) WHERE {
  { wd:]] .. qid .. [[ wdt:P674 ?c } UNION { ?c wdt:P1441 wd:]] .. qid .. [[ }
  OPTIONAL { ?c skos:altLabel ?alt . FILTER(LANG(?alt) = "en") }
  OPTIONAL { ?article schema:about ?c ; schema:isPartOf <https://en.wikipedia.org/> }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
} GROUP BY ?c ?cLabel ?cDescription ?article LIMIT 120]]
        local r = getJSON(E.sparql .. "?format=json&query=" .. urlencode(q))
        for _i, b in ipairs(r and r.results and r.results.bindings or {}) do
            local label = b.cLabel and b.cLabel.value
            if label and not label:match("^Q%d+$") then
                local alts = {}
                for a in tostring(b.alts and b.alts.value or ""):gmatch("[^|]+") do alts[#alts + 1] = a end
                table.insert(out.chars, { label = label, desc = b.cDescription and b.cDescription.value, alts = alts,
                    wp = b.article and b.article.value and b.article.value:match("/wiki/(.+)$") })
            end
        end
        -- a fan wiki for the book, its series or its world
        local fq = "SELECT ?f WHERE { { wd:" .. qid .. " wdt:P4073 ?f } UNION { wd:" .. qid .. " wdt:P179 ?s . ?s wdt:P4073 ?f } UNION { wd:"
            .. qid .. " wdt:P1434 ?u . ?u wdt:P4073 ?f } } LIMIT 1"
        local fr = getJSON(E.sparql .. "?format=json&query=" .. urlencode(fq))
        local fb = fr and fr.results and fr.results.bindings and fr.results.bindings[1]
        out.fandom = fb and fb.f and fb.f.value
    end
    out.offline = M._net.calls > 0 and M._net.failed == M._net.calls
    return out
end

--- One list from both: an entry per person (Open Library's and Wikidata's
--- names for one person merged), and the places.
function M.merge(ol, wd, title, author)
    local out = { people = {}, places = {}, sources = {}, title = title, author = author,
        wikidata = wd and wd.qid, fandom = wd and wd.fandom }
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
    if ol and ol.found then
        table.insert(out.sources, "Open Library")
        for _i, n in ipairs(ol.people) do person(n) end
        for _i, n in ipairs(ol.places) do table.insert(out.places, { name = n, names = { n } }) end
    end
    for _i, c in ipairs(wd and wd.chars or {}) do
        local p
        for _j, n in ipairs({ c.label, unpack(c.alts) }) do p = p or seen[norm(n)] end
        p = p or person(c.label)
        p.name = c.label
        for _j, a in ipairs(c.alts) do
            if not seen[norm(a)] then seen[norm(a)] = p table.insert(p.names, a) end
        end
        if not seen[norm(c.label)] then seen[norm(c.label)] = p end
        local has = false
        for _j, n in ipairs(p.names) do if n == c.label then has = true end end
        if not has then table.insert(p.names, 1, c.label) end
        p.short = c.desc or p.short
        p.wp_title = c.wp or p.wp_title
    end
    if wd and #wd.chars > 0 then table.insert(out.sources, "Wikidata") end
    return out
end

local function urldecode(s) return (tostring(s):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

--- The start of each character's Wikipedia article (background only), 20
--- at a time: { [title] = text }.
function M.fetchWiki(titles)
    local E = M.endpoints()
    local out = {}
    for i = 1, math.min(#titles, 60), 20 do
        local batch = {}
        for j = i, math.min(i + 19, #titles) do batch[#batch + 1] = urldecode(titles[j]):gsub("_", " ") end
        local r = getJSON(E.wp .. "/w/api.php?action=query&format=json&formatversion=2&prop=extracts&exintro=1&explaintext=1&exlimit=20&redirects=1&titles="
            .. urlencode(table.concat(batch, "|")))
        local q = r and r.query or {}
        local back = {}
        for _k, n in ipairs(q.normalized or {}) do back[n.to] = n.from end
        for _k, n in ipairs(q.redirects or {}) do back[n.to] = back[n.from] or n.from end
        for _k, pg in ipairs(q.pages or {}) do
            if type(pg.extract) == "string" and pg.extract ~= "" then
                out[back[pg.title] or pg.title] = { text = firstSentences(pg.extract, 900), title = pg.title }
            end
        end
    end
    return out
end

--- The start of each name's page on the fan wiki (background only):
--- { [name] = text }.
function M.fetchFan(fandom, names)
    local E = M.endpoints()
    local out = {}
    if not (fandom and fandom:match("^[%w%-%.]+$")) then return out end
    local base = string.format(E.fandom, fandom) .. "/api.php"
    for i = 1, math.min(#names, 15) do
        local sr = getJSON(base .. "?action=query&list=search&srlimit=1&format=json&formatversion=2&srsearch=" .. urlencode(names[i]))
        local hit = sr and sr.query and sr.query.search and sr.query.search[1]
        if hit and hit.title then
            local pr = getJSON(base .. "?action=parse&prop=text&section=0&format=json&formatversion=2&page=" .. urlencode(hit.title))
            local text = plainText(pr and pr.parse and pr.parse.text)
            if text then out[names[i]] = firstSentences(text, 1200) end
        end
    end
    return out
end

-- ---------------------------------------------------------------- the book (background, with the document)

--- Every passage each name is in, from the book itself (a forked process
--- with the open document: KOReader's own full-text search, once for all
--- the names). Returns { people = { hits… }, places = { hits… } } by index.
function M.findMentions(doc, people, places)
    local owner, names = {}, {}
    local function add(kind, i, n)
        -- (very short names would find everything)
        if #n >= 3 and not owner[n] then owner[n] = { kind, i } names[#names + 1] = n end
    end
    for _k, kind in ipairs({ "people", "places" }) do
        for i, e in ipairs(kind == "people" and people or places) do
            for _j, n in ipairs(e.names or { e.name }) do add(kind, i, n) end
            -- (the last word of a long name too, "Ahab" of "Captain Ahab",
            -- when no other entry has it)
            for _j, n in ipairs(e.extra or {}) do add(kind, i, n) end
        end
    end
    -- (the longest first: "Captain Ahab" is one passage, not "Ahab" too)
    table.sort(names, function(a, b) return #a > #b end)
    local function esc(n) return (n:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?\\|{}])", "\\%1")) end
    local out = { people = {}, places = {} }
    local seen = {}
    local function take(h, n)
        local o = owner[n]
        if not o then return end
        local key = h.start
        -- (none in links: a table of contents isn't a passage)
        if not key or key:find("/a[/%[]") then return end
        local node, off = tostring(key):match("^(.-)%.(%d+)$")
        off = tonumber(off) or 0
        local sk = o[1] .. o[2] .. (node or key)
        for _o, x in ipairs(seen[sk] or {}) do if math.abs(x - off) < 24 then return end end
        seen[sk] = seen[sk] or {}
        table.insert(seen[sk], off)
        local page
        pcall(function() page = doc:getPageFromXPointer(key) end)
        local list = out[o[1]]
        list[o[2]] = list[o[2]] or {}
        table.insert(list[o[2]], { xp = key, page = page,
            text = ((h.prev_text or "") .. (h.matched_text or n) .. (h.next_text or "")):gsub("%s+", " ") })
    end
    local parts = {}
    for _i, n in ipairs(names) do parts[#parts + 1] = esc(n) end
    local ok, res = false, nil
    if #parts > 0 then
        ok, res = pcall(doc.findAllText, doc, "\\b(?:" .. table.concat(parts, "|") .. ")\\b", false, 9, 30000, true)
    end
    if ok and type(res) == "table" then
        for _k, h in ipairs(res) do take(h, h.matched_text) end
    else
        -- (one name at a time, if the search can't take them all at once)
        for _i, n in ipairs(names) do
            local ok2, r = pcall(doc.findAllText, doc, "\\b" .. esc(n) .. "\\b", false, 9, 600, true)
            for _k, h in ipairs(ok2 and r or {}) do take(h, n) end
        end
    end
    for _k, list in pairs(out) do
        for _i, hits in pairs(list) do table.sort(hits, function(a, b) return (a.page or 0) < (b.page or 0) end) end
    end
    return out
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

function M.saveTo(p, data)
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

local function notify(text)
    pcall(function()
        local N = require("ui/widget/notification")
        N:notify(text, N.SOURCE_ALWAYS_SHOW)
    end)
end

--- Download what's known and find it in the book; done(data | nil, why).
--- The title and author to look for, from the book.
function M.bookQuery(ui)
    local props = ui.doc_props or {}
    return M.shortTitle(props.display_title or props.title or ""), M.authorName(props.authors)
end

M.busy = {}

--- Downloads what's known and finds it in the book, in the background (you
--- keep reading): done(data) or done(nil, why, reason), reason "offline" /
--- "none" / "absent" / "closed" / "error". Open Library and Wikidata are
--- asked at the same time; then Wikipedia, the fan wiki and the search of
--- the book all at once. `pick`: a book chosen from M.candidates.
function M.download(ui, done, pick)
    local title, author = M.bookQuery(ui)
    if title == "" and not pick then return done(nil, _("This book has no title to look for."), "none") end
    local doc = ui.document
    local file = doc and doc.file
    local spath = path(ui)
    if not (file and spath) then return done(nil, _("X-Ray: this book can't keep one."), "error") end
    if M.busy[file] then
        notify(_("X-Ray is still downloading for this book."))
        return
    end
    M.busy[file] = true
    local function finish(...)
        M.busy[file] = nil
        return done(...)
    end
    local Async = require("bos_store").Async
    local ol, wd
    local function asked()
        if not (ol and wd) then return end
        if ol.offline and (wd.offline or not wd.qid) then
            return finish(nil, _("X-Ray: Open Library and Wikidata couldn't be reached. Check the Wi-Fi."), "offline")
        end
        local data = M.merge(ol, wd, pick and pick.title or title, author)
        if #data.people == 0 and #data.places == 0 then return finish(nil, nil, "none") end
        shortNames(data.people)
        -- (the book itself, while it's still open)
        local RUI = package.loaded["apps/reader/readerui"]
        if not (RUI and RUI.instance and RUI.instance.document == doc) then return finish(nil, nil, "closed") end
        local wp_titles, fan_names = {}, {}
        for _i, p in ipairs(data.people) do
            if p.wp_title then wp_titles[#wp_titles + 1] = p.wp_title end
            fan_names[#fan_names + 1] = p.name
        end
        local wiki, fan, hits = nil, nil, nil
        local left = 3
        local function one()
            left = left - 1
            if left > 0 then return end
            if type(hits) ~= "table" then return finish(nil, _("X-Ray: the book couldn't be searched."), "error") end
            local any_wiki, any_fan = false, false
            for _k, kind in ipairs({ "people", "places" }) do
                for i, e in ipairs(data[kind]) do
                    e.hits = hits[kind] and hits[kind][i] or {}
                    e.count = #e.hits
                    e.extra = nil
                    local w = wiki and e.wp_title and wiki[urldecode(e.wp_title):gsub("_", " ")]
                    if w then e.wiki, e.wiki_title, any_wiki = w.text, w.title, true end
                    if fan and fan[e.name] then e.fan, any_fan = fan[e.name], true end
                end
            end
            if any_wiki then table.insert(data.sources, "Wikipedia") end
            if any_fan then table.insert(data.sources, T("%1 fan wiki", data.fandom)) end
            -- (only who's in this book; the most mentioned first)
            local function keep(list)
                local out = {}
                for _i, e in ipairs(list) do if (e.count or 0) > 0 then out[#out + 1] = e end end
                table.sort(out, function(a, b) return a.count > b.count end)
                return out
            end
            data.people, data.places = keep(data.people), keep(data.places)
            data.version, data.at = M.VERSION, os.time()
            if #data.people == 0 and #data.places == 0 then return finish(nil, nil, "absent") end
            M.saveTo(spath, data)
            finish(data)
        end
        if #wp_titles > 0 then
            Async.run(function() return M.fetchWiki(wp_titles) end, function(ok, r) wiki = ok and r or nil one() end, 60)
        else one() end
        if data.fandom then
            Async.run(function() return M.fetchFan(data.fandom, fan_names) end, function(ok, r) fan = ok and r or nil one() end, 90)
        else one() end
        local people, places = data.people, data.places
        Async.run(function() return M.findMentions(doc, people, places) end, function(ok, r) hits = ok and r or nil one() end, 900)
    end
    Async.run(function() return M.fetchOL(title, author, pick) end, function(ok, r)
        ol = ok and type(r) == "table" and r or { people = {}, places = {}, offline = true }
        asked()
    end, 90)
    Async.run(function() return M.fetchWD(title, author, pick) end, function(ok, r)
        wd = ok and type(r) == "table" and r or { chars = {}, offline = true }
        asked()
    end, 90)
end

--- No X-Ray found by itself: the books that match, to choose from (and a
--- search of your own). `note` says why it's asking.
function M.choose(ui, query, note, finish)
    local _t, author = M.bookQuery(ui)
    local Async = require("bos_store").Async
    notify(T(_("X-Ray: looking for books called “%1”…"), query))
    Async.run(function() return M.candidates(query, author) end, function(ok, list, offline)
        if not ok or offline then
            UIManager:show(require("ui/widget/infomessage"):new{ text = _("X-Ray: Open Library and Wikidata couldn't be reached. Check the Wi-Fi."), timeout = 6 })
            return
        end
        list = type(list) == "table" and list or {}
        local o = { pg = 1 }
        local page
        local function another()
            local InputDialog = require("ui/widget/inputdialog")
            local dlg
            dlg = InputDialog:new{ title = _("Look for X-Ray under"), input = query,
                buttons = { { { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
                    { text = _("Search"), is_enter_default = true, callback = function()
                        local q = dlg:getInputText()
                        UIManager:close(dlg)
                        if q and q:match("%S") then page:onClose() M.choose(ui, q, nil, finish) end
                    end } } } }
            UIManager:show(dlg)
            dlg:onShowKeyboard()
        end
        page = Page:new{ caption = _("X-Ray"),
            draw = function(self, bb, y, w)
                local x = self.pad
                local H = Screen:getHeight()
                y = y + Page.wrap(bb, note or T(_("Which book is this? Matches for “%1”:"), query), Look.serif(15), x, y, w, 3, S(22)) + S(10)
                local r = Look.button(bb, x, y, w - Look.SHADOW_SMALL, S(38), T(_("Search for something else")), { size = 11 })
                self:hit(r, another)
                y = y + S(38) + Look.SHADOW_SMALL + S(16)
                local rh = S(66)
                local per = math.max(1, math.floor((H - y - S(60)) / rh))
                local pages = math.max(1, math.ceil(#list / per))
                o.pages = pages
                o.pg = math.max(1, math.min(o.pg, pages))
                if #list == 0 then
                    Page.wrap(bb, _("Nothing found under that name. Try the title alone, or another spelling."), Look.serif(15, false, true), x, y, w, 3, S(23), Look.GRAY)
                end
                for k = 1, per do
                    local c = list[(o.pg - 1) * per + k]
                    if not c then break end
                    local ry = y + (k - 1) * rh
                    Page.wrap(bb, c.title, Look.serif(16, true), x, ry, w, 1, S(24))
                    local sub = {}
                    if c.author then sub[#sub + 1] = c.author end
                    if c.year then sub[#sub + 1] = tostring(c.year) end
                    if c.desc and c.desc ~= "" then sub[#sub + 1] = c.desc end
                    sub[#sub + 1] = c.from
                    Page.wrap(bb, table.concat(sub, "  ·  "), Look.serif(12, false, true), x, ry + S(26), w, 1, S(20), Look.GRAY)
                    if k < per and list[(o.pg - 1) * per + k + 1] then bb:paintRect(x, ry + rh - S(10), w, 1, Look.LIGHT) end
                    self:hit(Geom:new{ x = x, y = ry - S(4), w = w, h = rh - S(4) }, function()
                        self:onClose()
                        notify(_("X-Ray: downloading in the background. Keep reading; it'll say when it's ready."))
                        M.download(ui, finish, c)
                    end)
                end
                if pages > 1 then
                    local fy = H - S(52)
                    local kw = S(56)
                    local rp = Look.button(bb, x, fy, kw, S(38), "\u{2039}", { size = 15, enabled = o.pg > 1 })
                    if o.pg > 1 then self:hit(rp, function() o.pg = o.pg - 1 self:refresh("ui") end) end
                    local rn = Look.button(bb, x + w - kw - Look.SHADOW_SMALL, fy, kw, S(38), "\u{203A}", { size = 15, enabled = o.pg < pages })
                    if o.pg < pages then self:hit(rn, function() o.pg = o.pg + 1 self:refresh("ui") end) end
                    Look.label(bb, T(_("%1 / %2"), o.pg, pages), x + kw, fy, w - 2 * kw, S(38), 12, { align = "center" })
                end
            end,
            on_swipe = function(self, dir)
                if dir == "west" and o.pg < (o.pages or 1) then o.pg = o.pg + 1 self:refresh("ui")
                elseif dir == "east" then if o.pg > 1 then o.pg = o.pg - 1 self:refresh("ui") else self:onClose() end end
            end,
        }
        M.chooser = page
        page:show()
    end, 60)
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
function M.openEntry(ui, e, kind)
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
                    -- (to the book: the list goes too)
                    self:onClose()
                    if M.list then pcall(function() M.list:onClose() end) end
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
function M.openList(ui, data)
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
                self:hit(Geom:new{ x = x, y = ry - S(4), w = w, h = rh - S(4) }, function() M.openEntry(ui, e, o.tab) end)
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

-- ---------------------------------------------------------------- the pop-up (from the dictionary)

local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")

local function inside(p, r) return p and r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end

--- One person or place, in a window where the dictionary was: who it is,
--- where it's mentioned, and keys for its passages and the whole X-Ray.
local Popup = InputContainer:extend{
    name = "stui_xray_popup",
    ui = nil, data = nil, entry = nil, kind = nil, word = nil, anchor = nil,
}

function Popup:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local all = function() return Geom:new{ x = 0, y = 0, w = W, h = H } end
    self.ges_events = {
        XTap = { GestureRange:new{ ges = "tap", range = all } },
        XSwipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
    local a = self.anchor
    self.w = math.min(W - 2 * S(10), (a and a.w and a.w > S(200)) and a.w or (W - 2 * S(10)))
    self.x = (a and a.x) and math.max(S(10), math.min(W - self.w - S(10), a.x)) or math.floor((W - self.w) / 2)
    self.h = self:layout(nil)
    local y
    if a and a.y then
        y = a.y
        if y + self.h > H - S(10) then y = a.y + (a.h or 0) - self.h end
    else
        y = H - self.h - S(40)
    end
    self.y = math.max(S(10), math.min(H - self.h - S(10), y))
    self.dimen = Geom:new{ x = self.x, y = self.y, w = self.w + Look.SHADOW, h = self.h + Look.SHADOW }
end

function Popup:getSize() return self.dimen end

--- Draws (or with bb nil, only measures) the card; returns its height.
function Popup:layout(bb)
    local pad = S(16)
    local x0, w = (self.x or 0), self.w
    local x, iw = x0 + pad, w - 2 * pad
    local y0 = self.y or 0
    local y = y0 + S(12)
    local e, ui = self.entry, self.ui
    self.hits = {}
    local key = S(42)
    if bb then
        self.close_rect = Geom:new{ x = x0 + w - key - S(4), y = y0, w = key + S(4), h = key + S(6) }
        Look.label(bb, "\u{00D7}", x0 + w - key - S(4), y0 + S(4), key, key, 18, { align = "center", keep_case = true })
    end
    local function text(t, face, lines, lh, color, width)
        local h = Page.wrap(bb, t, face, x, y, width or iw, lines, lh, color)
        y = y + h
        return h
    end
    if e then
        text(e.name, Look.serif(21, true), 2, S(30), nil, iw - key)
        y = y + S(2)
        local hits = visibleHits(ui, e)
        local sub = {}
        if e.short then sub[#sub + 1] = e.short end
        local n = #hits
        if spoilerFree() and n < (e.count or 0) then
            sub[#sub + 1] = T(n == 1 and _("%1 mention so far") or _("%1 mentions so far"), n)
        else
            sub[#sub + 1] = T((e.count or 0) == 1 and _("%1 mention") or _("%1 mentions"), e.count or 0)
        end
        text(table.concat(sub, "  ·  "), Look.serif(13, false, true), 2, S(20), Look.GRAY)
        y = y + S(10)
        if bb then strip(bb, ui, e, x, y, iw, S(12)) end
        y = y + S(24)
        local body, label
        if e.wiki then
            body = e.wiki
        elseif e.fan and self.fan_shown then
            body = e.fan
        elseif hits[1] then
            label = hits[1].page and T(_("First appears, page %1"), hits[1].page) or _("First appears")
            body = "…" .. hits[1].text .. "…"
        end
        if label then
            if bb then Look.label(bb, label, x, y, iw, S(18), 9, { color = Look.GRAY }) end
            y = y + S(22)
        end
        if body then text(body, Look.serif(14, false, label ~= nil), 7, S(22)) y = y + S(8) end
        if e.fan and not e.wiki and not self.fan_shown then
            if bb then
                local r = Look.button(bb, x, y, S(250), S(34), _("Fan wiki (may spoil)"), { size = 10 })
                self.hits[#self.hits + 1] = { rect = r, fn = function() self.fan_shown = true self:redraw() end }
            end
            y = y + S(34) + Look.SHADOW_SMALL + S(10)
        end
    else
        text(_("X-Ray"), Look.serif(21, true), 1, S(30), nil, iw - key)
        y = y + S(6)
        text(T(_("“%1” isn't one of the people or places X-Ray knows in this book."), self.word or ""), Look.serif(14), 3, S(22))
        y = y + S(12)
    end
    -- the keys
    y = y + S(4)
    local kh = S(38)
    local keys = {}
    if e then keys[#keys + 1] = { text = _("Passages"), fn = function() self:onClose() M.openEntry(ui, e, self.kind) end } end
    keys[#keys + 1] = { text = _("Everyone in X-Ray"), fn = function() self:onClose() M.openList(ui, self.data) end }
    local gap = S(10)
    local kw = math.floor((iw - Look.SHADOW_SMALL - (#keys - 1) * gap) / #keys)
    for i, k in ipairs(keys) do
        local kx = x + (i - 1) * (kw + gap)
        if bb then
            local r = Look.button(bb, kx, y, kw, kh, k.text, { size = 11 })
            self.hits[#self.hits + 1] = { rect = r, fn = k.fn }
        end
    end
    y = y + kh + Look.SHADOW_SMALL + pad
    return y - y0
end

function Popup:paintTo(bb, _x, _y)
    Look.shadow(bb, self.x, self.y, self.w, self.h, Look.SHADOW)
    local r = S(14)
    bb:paintRoundedRect(self.x, self.y, self.w, self.h, Look.PAPER, r)
    bb:paintBorder(self.x, self.y, self.w, self.h, math.max(1, S(1.5)), Look.INK, r, true)
    local h = self:layout(bb)
    if h ~= self.h then
        -- (grew or shrank: the fan wiki opened) lay out again next paint
        self.h = h
        self.dimen.h = h + Look.SHADOW
    end
end

function Popup:redraw()
    local old = Geom:new{ x = self.dimen.x, y = self.dimen.y, w = self.dimen.w, h = self.dimen.h }
    self.h = self:layout(nil)
    local H = Screen:getHeight()
    if self.y + self.h > H - S(10) then self.y = math.max(S(10), H - self.h - S(10)) end
    self.dimen = Geom:new{ x = self.x, y = self.y, w = self.w + Look.SHADOW, h = self.h + Look.SHADOW }
    UIManager:setDirty(self.ui and self.ui.dialog or "all", "ui", old)
    UIManager:setDirty(self, "ui", self.dimen)
end

function Popup:onXTap(_, ges)
    if inside(ges.pos, self.close_rect) then return self:onClose() end
    for _i, h in ipairs(self.hits or {}) do
        if inside(ges.pos, h.rect) then
            pcall(function()
                Screen.bb:invertRect(h.rect.x, h.rect.y, h.rect.w, h.rect.h)
                UIManager:setDirty(nil, "fast", h.rect)
                UIManager:forceRePaint()
            end)
            UIManager:nextTick(h.fn)
            return true
        end
    end
    if not inside(ges.pos, self.dimen) then return self:onClose() end
    return true
end

function Popup:onXSwipe(_, ges)
    if not inside(ges.pos, self.dimen) then return self:onClose() end
    return true
end

function Popup:onClose()
    UIManager:close(self)
    return true
end

function Popup:onShow()
    UIManager:setDirty(self, "ui", self.dimen)
    return true
end

function Popup:onCloseWidget()
    UIManager:setDirty(self.ui and self.ui.dialog or "all", "ui", self.dimen)
end

--- The pop-up for `word` (its person or place, or a line saying it's none).
function M.popup(ui, data, word, anchor)
    local e, kind = M.find(data, word)
    local p = Popup:new{ ui = ui, data = data, entry = e, kind = kind, word = word, anchor = anchor }
    M.shown = p
    UIManager:show(p)
    return p
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

--- From the dictionary: the pop-up for `word` (its person or place) where
--- the dictionary was (`anchor`). With none yet: asks, then downloads it.
function M.open(ui, word, anchor)
    if not (ui and ui.document) then return end
    local data = M.load(ui)
    if data then return M.popup(ui, data, word, anchor) end
    return askDownload(ui, word)
end

--- From the reader menu: the whole X-Ray (people and places).
function M.openFull(ui)
    if not (ui and ui.document) then return end
    local data = M.load(ui)
    if data then return M.openList(ui, data) end
    return askDownload(ui)
end

askDownload = function(ui, word)
    if ui.document.file and M.busy[ui.document.file] then
        notify(_("X-Ray is still downloading for this book."))
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Download X-Ray for this book?\n\nIts people and places, with what Open Library, Wikidata and Wikipedia know about them (and a fan wiki, if the book has one), are downloaded once; then every passage they're in is found in the book. It happens in the background while you read, and works without Wi-Fi after that."),
        ok_text = _("Download"),
        ok_callback = function()
            require("ui/network/manager"):runWhenOnline(function()
                local title = M.bookQuery(ui)
                local finish
                finish = function(got, why, reason)
                    if got then
                        -- (you're reading: only say so; X-Ray opens from a name's
                        -- look-up or the reader menu)
                        notify(T(_("X-Ray ready for “%1”: %2 people, %3 places"), got.title or title, #got.people, #got.places))
                    elseif reason == "none" or reason == "absent" then
                        -- (not found by itself: the closest books, to choose from)
                        UIManager:show(ConfirmBox:new{
                            text = reason == "absent" and _("X-Ray: the names found for this book aren't in it. Choose the book from a list of matches?")
                                or T(_("X-Ray: no characters found for “%1” by itself. Choose the book from a list of matches?"), title),
                            ok_text = _("Choose"),
                            ok_callback = function()
                                M.choose(ui, title ~= "" and title or (word or ""), _("Which book is this?"), finish)
                            end,
                        })
                    elseif reason == "closed" then
                        notify(_("X-Ray stopped: the book was closed. Try again from the dictionary."))
                    else
                        UIManager:show(require("ui/widget/infomessage"):new{ text = why or _("X-Ray couldn't be made."), timeout = 6 })
                    end
                end
                notify(_("X-Ray: downloading in the background. Keep reading; it'll say when it's ready."))
                M.download(ui, finish)
            end)
        end,
    })
end

return M
