--[[
A website as one of your libraries in the store, when it has no catalogue
(OPDS) to read: the store searches it as a person would, with its own search
form, and reads the page of results.

  * Adding it: the site's address. Its search is found on that page (the
    form with a search field); or give the address of a search you did on
    the site, with the word you searched for in it, or {q} where the words go
    (https://example.org/search?q={q}).
  * Searching it: its results page is read for links. A link straight to a
    book file (.epub, .pdf, .mobi, .azw3, .fb2, .cbz, .djvu, .txt) is a book
    you can download; any other link of the site is a book's page, read when
    you open it for the files it offers, its cover and its description. Only
    links that match every word you searched for are kept (the store's own
    filter), so menus and the like drop out.

All of it blocking (network): run in the background (the store's searches
and book pages already are).

  M.find(url)               { name, url, search, kind = "web" } | nil, why
  M.search(lib, query, page) { books, total, has_next } | nil, why
  M.hydrate(book)           the book with its files (and cover, description)
--]]

local _ = require("gettext")

local M = {}

M.EXT = { epub = "EPUB", pdf = "PDF", mobi = "MOBI", azw3 = "AZW3", azw = "AZW3", fb2 = "FB2",
    cbz = "CBZ", cbr = "CBR", djvu = "DJVU", txt = "TXT", rtf = "RTF", docx = "DOCX", kepub = "EPUB" }

local function O() return require("bookdrop_opds_provider") end

local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", ndash = "–", mdash = "—", hellip = "…",
    rsquo = "’", lsquo = "‘", rdquo = "”", ldquo = "“" }
local function decode(s)
    s = tostring(s or "")
    s = s:gsub("&#x(%x+);", function(h) local ok, c = pcall(require("util").unicodeCodepointToUtf8, tonumber(h, 16)) return ok and c or "" end)
    s = s:gsub("&#(%d+);", function(n) local ok, c = pcall(require("util").unicodeCodepointToUtf8, tonumber(n)) return ok and c or "" end)
    s = s:gsub("&(%a+);", function(n) return ENT[n:lower()] or ("&" .. n .. ";") end)
    return s
end
M._decode = decode

local function text(html)
    local s = tostring(html or ""):gsub("<script.-</script>", " "):gsub("<style.-</style>", " "):gsub("<[^>]+>", " ")
    return (decode(s):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function attr(tag, name)
    return tag:match("%s" .. name .. '%s*=%s*"([^"]*)"') or tag:match("%s" .. name .. "%s*=%s*'([^']*)'")
        or tag:match("%s" .. name .. "%s*=%s*([^%s>\"']+)")
end
M._attr = attr

local function fetch(url)
    return O()._requestPayload(url, "text/html, application/xhtml+xml, */*")
end

local function absolute(base, href)
    if not href or href == "" then return nil end
    href = decode(href)
    local ok, a = pcall(O()._absolute, base, href)
    return ok and a or nil
end

local function host(url) return (tostring(url):gsub("^https?://", ""):gsub("^[^/@]*@", ""):gsub("[/:?#].*$", "")):lower() end
local function siteOf(h) return (h:gsub("^www%.", "")) end

local function extOf(url)
    local path = tostring(url):gsub("[?#].*$", ""):lower()
    local e = path:match("%.([%w]+)$")
    if e and M.EXT[e] then return e end
    -- (…/download?format=epub, …/epub/123)
    local q = tostring(url):lower():match("[?&]format=(%w+)") or tostring(url):lower():match("[?&]type=(%w+)")
    if q and M.EXT[q] then return q end
end
M._extOf = extOf

-- ---------------------------------------------------------------- the search form

local NAMES = { q = 1, query = 1, s = 2, search = 2, keyword = 3, keywords = 3, term = 3, text = 4, title = 5 }

--- The site's search, from a page of it: a template with {searchTerms}.
local function formSearch(page_url, html)
    local best, best_rank
    for form in html:gmatch("<[Ff][Oo][Rr][Mm][^>]*>.-</[Ff][Oo][Rr][Mm]>") do
        local open = form:match("^<[^>]+>")
        local method = (attr(open, "method") or "get"):lower()
        if method == "get" and not form:lower():find('type%s*=%s*["\']?password') then
            local field, rank
            local params = {}
            for input in form:gmatch("<[Ii][Nn][Pp][Uu][Tt][^>]*>") do
                local ty = (attr(input, "type") or "text"):lower()
                local name = attr(input, "name")
                if name then
                    if ty == "hidden" then
                        params[#params + 1] = { name, attr(input, "value") or "" }
                    elseif ty == "search" or ty == "text" then
                        local r = (ty == "search" and 0 or 1) + (NAMES[name:lower()] or 6)
                        if not rank or r < rank then field, rank = name, r end
                    end
                end
            end
            if field and (not best_rank or rank < best_rank) then
                local action = absolute(page_url, attr(open, "action") or page_url) or page_url
                action = action:gsub("[?#].*$", "")
                local url = require("socket.url")
                local q = {}
                for _i, p in ipairs(params) do q[#q + 1] = url.escape(p[1]) .. "=" .. url.escape(decode(p[2])) end
                q[#q + 1] = url.escape(field) .. "={searchTerms}"
                best, best_rank = action .. "?" .. table.concat(q, "&"), rank
            end
        end
    end
    return best
end
M._formSearch = formSearch

--- A search address someone typed: {q} (or %s) where the words go, or the
--- address of a search for a word, that word standing for the words.
local function typedSearch(url, word)
    if url:find("{q}", 1, true) then return (url:gsub("{q}", "{searchTerms}")) end
    if url:find("%s", 1, true) then return (url:gsub("%%s", "{searchTerms}")) end
    if url:find("{searchTerms", 1, true) then return url end
    if word and word ~= "" then
        local esc = require("socket.url").escape(word)
        for _i, w in ipairs({ word, esc, (word:gsub(" ", "+")) }) do
            local a, b = url:find(w, 1, true)
            if a and url:sub(1, a - 1):find("[?/=]") then return url:sub(1, a - 1) .. "{searchTerms}" .. url:sub(b + 1) end
        end
    end
end
M._typedSearch = typedSearch

--- The site at `url` as a library: its name and its search.
function M.find(url, word)
    local search = typedSearch(url, word)
    local site = search and url:gsub("[?#].*$", "") or url
    local html, err = fetch(site)
    if not html and not search then return nil, tostring(err or _("No answer.")) end
    html = html or ""
    local name = text(html:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Tt][Ii][Tt][Ll][Ee]>") or "")
    name = name:gsub("%s*[|·–—-]%s*[^|·–—-]*$", "")
    if name == "" or #name > 40 then name = siteOf(host(url)) end
    search = search or formSearch(site, html)
    if not search then
        return nil, _("No search was found on that page. Search the site for a word in a browser and add the address of the results page, with the word in it (or {q} where the words go).")
    end
    return { name = name, url = site, search = search, kind = "web" }
end

-- ---------------------------------------------------------------- results

local SKIP = { ["home"] = 1, ["next"] = 1, ["previous"] = 1, ["prev"] = 1, ["login"] = 1, ["log in"] = 1, ["sign in"] = 1,
    ["sign up"] = 1, ["register"] = 1, ["search"] = 1, ["about"] = 1, ["contact"] = 1, ["help"] = 1, ["more"] = 1 }

--- "Dracula by Bram Stoker" → "Dracula", "Bram Stoker".
local function titleAuthor(s)
    local t, a = s:match("^(.-)%s+[Bb]y%s+(.+)$")
    if t and #t > 0 and #a < 60 then return t, a end
    t, a = s:match("^(.-)%s+[-–—|]%s+(.+)$")
    if t and #t > 0 and #a < 60 and not a:find("%d%d%d%d") then return t, a end
    return s, nil
end

--- The books on a page of results (or any page of the site).
function M.parse(page_url, html, id, source_name)
    local books, seen = {}, {}
    local site = siteOf(host(page_url))
    html = tostring(html)
    local pos = 1
    while true do
        local a0, a1, open, inner = html:find("(<[Aa]%s[^>]*>)(.-)</[Aa]>", pos)
        if not a0 then break end
        pos = a1 + 1
        -- (what's written by the link: often its author, its year)
        local near = text(html:sub(a1 + 1, a1 + 400)):sub(1, 160)
        local href = attr(open, "href")
        local url = href and not href:match("^%s*javascript:") and not href:match("^mailto:") and not href:match("^#")
            and absolute(page_url, href)
        if url and url:match("^https?://") and not seen[url] then
            local label = text(inner)
            if label == "" then label = decode(attr(open, "title") or "") end
            if label == "" then
                local img = inner:match("<[Ii][Mm][Gg][^>]*>")
                label = img and decode(attr(img, "alt") or "") or ""
            end
            local ext = extOf(url)
            local same = siteOf(host(url)) == site
            local lab = label:lower():gsub("[^%w ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
            local just_format = lab == "" or lab == "download" or M.EXT[lab] ~= nil or lab:match("^download %w+$") ~= nil
                or lab:match("^%w+ download$") ~= nil
            if ext and just_format and books[#books] then
                -- ("EPUB" by a book: that book's file)
                seen[url] = true
                local last = books[#books]
                last.acquisitions = last.acquisitions or {}
                table.insert(last.acquisitions, { url = url, extension = ext == "kepub" and "epub" or ext, format = M.EXT[ext] })
                last.format = last.acquisitions[1].format
            elseif ext then
                seen[url] = true
                local name = label ~= "" and label or (url:gsub("[?#].*$", ""):match("([^/]+)$") or url):gsub("%.%w+$", ""):gsub("[_%-]", " ")
                local t, a = titleAuthor(name)
                a = a or near:match("^[Bb]y%s+([^,;|%(%)%[%]]+)")
                if a then a = a:gsub("%s+$", "") end
                books[#books + 1] = { id = id .. ":" .. url, provider = id, provider_id = url, title = t, author = a or "",
                    subjects = name .. " " .. near, source = source_name, format = M.EXT[ext], web = true,
                    acquisitions = { { url = url, extension = ext == "kepub" and "epub" or ext, format = M.EXT[ext] } } }
            elseif same and #label >= 3 and #label <= 160 and not SKIP[label:lower()] and url ~= page_url
                    and not url:gsub("[?#].*$", ""):match("^https?://[^/]+/?$") then
                seen[url] = true
                local t, a = titleAuthor(label)
                a = a or near:match("^[Bb]y%s+([^,;|%(%)%[%]]+)")
                if a then a = a:gsub("%s+$", "") end
                local img = inner:match("<[Ii][Mm][Gg][^>]*>")
                books[#books + 1] = { id = id .. ":" .. url, provider = id, provider_id = url, title = t, author = a or "",
                    subjects = label .. " " .. near, source = source_name, format = "EBOOK", web = true, web_page = url,
                    cover_url = img and absolute(page_url, attr(img, "src") or attr(img, "data-src")) or nil }
            end
            if #books >= 60 then break end
        end
    end
    return books
end

function M.search(lib, query, page)
    local fill = require("bos_store_libs")._fill
    local url = fill(lib.search, query, page or 1)
    local html, err = fetch(url)
    if not html then return nil, lib.name .. ": " .. tostring(err) end
    local books = M.parse(url, html, lib.id, lib.name)
    return { books = books, total = #books, has_next = false }
end

--- A book's page: its files (links to book files; else links that say
--- what they are: "EPUB", "Download"), cover and description.
function M.hydrate(book)
    if book.acquisitions and #book.acquisitions > 0 then return book end
    if not book.web_page then return nil, _("This page offers no book file.") end
    local html, err = fetch(book.web_page)
    if not html then return nil, tostring(err) end
    local acqs, seen = {}, {}
    local maybe = {}
    for open, inner in html:gmatch("(<[Aa]%s[^>]*>)(.-)</[Aa]>") do
        local url = absolute(book.web_page, attr(open, "href"))
        if url and url:match("^https?://") and not seen[url] then
            local ext = extOf(url)
            local label = text(inner):lower()
            if not ext then
                for e in pairs(M.EXT) do
                    if label:find("%f[%w]" .. e .. "%f[%W]") then ext = e break end
                end
                if ext then maybe[#maybe + 1] = { url = url, extension = ext == "kepub" and "epub" or ext, format = M.EXT[ext] } end
            else
                seen[url] = true
                acqs[#acqs + 1] = { url = url, extension = ext == "kepub" and "epub" or ext, format = M.EXT[ext] }
            end
        end
    end
    if #acqs == 0 then acqs = maybe end
    -- EPUB first, then the others
    table.sort(acqs, function(a, b) return (a.extension == "epub" and 0 or 1) < (b.extension == "epub" and 0 or 1) end)
    book.acquisitions = acqs
    book.format = acqs[1] and acqs[1].format or book.format
    local function meta(prop)
        for tag in html:gmatch("<[Mm][Ee][Tt][Aa][^>]*>") do
            local p = attr(tag, "property") or attr(tag, "name")
            if p and p:lower() == prop then return decode(attr(tag, "content") or "") end
        end
    end
    book.cover_url = book.cover_url or absolute(book.web_page, meta("og:image"))
    local desc = meta("og:description") or meta("description")
    if desc and desc ~= "" and (not book.description or book.description == "") then book.description = desc end
    local au = meta("author") or meta("book:author")
    if au and au ~= "" and (book.author or "") == "" then book.author = au end
    if #acqs == 0 then return nil, _("This page offers no book file the store can download.") end
    return book
end

return M
