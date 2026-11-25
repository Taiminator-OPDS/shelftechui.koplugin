local ffi = require("ffi")
local http = require("socket.http")
local luxl = require("luxl")
local socketutil = require("socketutil")
local url = require("socket.url")

local OPDS = {
    page_size = 10,
    max_response_bytes = 6 * 1024 * 1024,
}

-- THE BUILT-IN OPDS LIBRARIES (Gutenberg, Standard Ebooks, textos.info,
-- Gallica). OPDS is the Atom-based catalogue format most free ebook sites
-- publish; this file downloads a feed, reads each <entry> as a book
-- (entryToBook) and its acquisition links as the download files.
--
-- Each library is a table of URL templates:
--   name              shown in the store
--   search            the URL asked when you type; %s is replaced by what
--                     you typed (URL-escaped). If `direct_page` is set it
--                     also takes the page number as a second %d.
--   home              the URL used for a shelf with no query (storefront,
--                     "Most popular" with nothing typed). %d = page number
--                     when `direct_page` is set.
--   newest            optional: used instead of `home` when nothing is
--                     typed and the sort is "Newest". Any sort id from
--                     bos_store.lua's M.SORTS can be given its own URL the
--                     same way (key = the sort id); see sourceUrl().
--   direct_page       the site takes ?page=N in the URL. Without it, page
--                     2+ is reached by following each feed's rel="next"
--                     link from page 1 (slower: one request per page).
--   default_language  language given to books whose entry doesn't say, so
--                     the store's language filter can still sort them.
--
-- To add another OPDS library permanently: add an entry here with a new
-- id, then list that id in bookdrop_catalog_provider.lua (source_order,
-- sources, SOURCE_PRIORITY). Libraries you add from the store's ☰ menu
-- don't go here; they live in bos_store_libs.lua.
OPDS.sources = {
    gutenberg = {
        name = "Project Gutenberg",
        home = "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads",
        newest = "https://www.gutenberg.org/ebooks/search.opds/?sort_order=release_date",
        search = "https://www.gutenberg.org/ebooks/search.opds/?query=%s",
    },
    standardebooks = {
        name = "Standard Ebooks",
        home = "https://standardebooks.org/feeds/opds/all?per-page=10&page=%d",
        search = "https://standardebooks.org/feeds/opds/all?query=%s&per-page=10&page=%d",
        default_language = "en",
        direct_page = true,
    },
    textos = {
        name = "textos.info",
        home = "https://www.textos.info/populares.atom",
        newest = "https://www.textos.info/novedades.atom",
        search = "https://www.textos.info/busqueda.atom?query=%s",
        default_language = "es",
    },
    gallica = {
        name = "Gallica",
        home = "https://gallica.bnf.fr/services/engine/search/opds?operation=searchRetrieve&version=1.2&exactSearch=false&query=dc.formatspecific%20all%20%22epub%22%20sortby%20indexationdate%2Fsort.descending&filter=provenance%20all%20%22bnf.fr%22",
        search = "https://gallica.bnf.fr/services/engine/search/opds?operation=searchRetrieve&version=1.2&exactSearch=false&query=%s&filter=provenance%%20all%%20%%22bnf.fr%%22",
        default_language = "fr",
    },
}

-- The file types this provider understands, in the order a book's
-- downloads are listed (the first is offered as the main Download button).
-- Reorder to prefer another format; add a type here, in FORMAT_LABELS and
-- in extensionFromLink() to support a new one.
local FORMAT_ORDER = { "epub", "azw3", "mobi", "pdf", "djvu", "cbz", "txt" }
local FORMAT_LABELS = {
    epub = "EPUB", azw3 = "AZW3", mobi = "MOBI", pdf = "PDF",
    djvu = "DJVU", cbz = "CBZ", txt = "TXT",
}

local entities = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
}

local function decodeEntities(value)
    value = tostring(value or "")
    value = value:gsub("&#x([%da-fA-F]+);", function(number)
        local codepoint = tonumber(number, 16)
        return codepoint and require("util").unicodeCodepointToUtf8(codepoint) or ""
    end)
    value = value:gsub("&#(%d+);", function(number)
        local codepoint = tonumber(number)
        return codepoint and require("util").unicodeCodepointToUtf8(codepoint) or ""
    end)
    return value:gsub("&([%a]+);", function(entity)
        return entities[entity] or ("&" .. entity .. ";")
    end)
end

-- A small XML reader (KOReader's luxl): the feed as a tree of
-- { name, attributes, children, text } nodes. children()/child()/nodeText()
-- below walk it.
local function parseXml(xml)
    xml = tostring(xml or "")
        :gsub("<%?xml.-%?>", "")
        :gsub("<%?xml%-stylesheet.-%?>", "")
        :gsub("<!%-%-.-%-%->", "")
    xml = xml:gsub("<!%[CDATA%[(.-)%]%]>", function(value)
        return value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    end)

    local lexer = luxl.new(xml, #xml)
    local root = { name = "_root", attributes = {}, children = {}, text = "" }
    local stack = { root }
    local attribute_name
    for event, offset, size in lexer:Lexemes() do
        local value = ffi.string(lexer.buf + offset, size)
        if event == luxl.EVENT_START then
            local node = { name = value, attributes = {}, children = {}, text = "" }
            local parent = stack[#stack]
            parent.children[#parent.children + 1] = node
            stack[#stack + 1] = node
        elseif event == luxl.EVENT_ATTR_NAME then
            attribute_name = decodeEntities(value)
        elseif event == luxl.EVENT_ATTR_VAL then
            if attribute_name then
                stack[#stack].attributes[attribute_name] = decodeEntities(value)
                attribute_name = nil
            end
        elseif event == luxl.EVENT_TEXT then
            local current = stack[#stack]
            current.text = current.text .. decodeEntities(value)
        elseif event == luxl.EVENT_END and #stack > 1 then
            stack[#stack] = nil
        end
    end
    return root.children[1]
end

local function children(node, name)
    local found = {}
    for _, child in ipairs(node and node.children or {}) do
        if child.name == name then found[#found + 1] = child end
    end
    return found
end

local function child(node, ...)
    for name_number = 1, select("#", ...) do
        local name = select(name_number, ...)
        for _, candidate in ipairs(node and node.children or {}) do
            if candidate.name == name then return candidate end
        end
    end
end

local function nodeText(node)
    if not node then return "" end
    local pieces = { node.text or "" }
    for _, nested in ipairs(node.children or {}) do
        pieces[#pieces + 1] = nodeText(nested)
    end
    local cleaned = table.concat(pieces, " "):gsub("<.->", " "):gsub("%s+", " ")
        :gsub("^%s+", ""):gsub("%s+$", "")
    return cleaned
end

-- HOW THE STORE ASKS A SITE
-- Built-in libraries (OPDS.sources, Gutendex, archive.org) are asked as
-- "KOReader Bookdrop": they serve apps and some ask apps to say who they are.
-- Every other site (catalogues and websites people add themselves) is asked
-- the way a web browser asks: a browser's User-Agent, Accept and
-- Accept-Language headers, cookies kept while following its redirects (many
-- sites set one on the first answer and refuse the next request without it),
-- and the page it came from as Referer. That gets past sites that simply
-- refuse unfamiliar clients.
-- It does not get past bot protection (Cloudflare's or DDoS-Guard's
-- "checking your browser" pages, captchas): those check for a real browser
-- running the page, and the store doesn't pretend to be one. blockReason()
-- recognises them so the store can say "blocks apps: Cloudflare check"
-- instead of a bare 403.
OPDS.BROWSER_UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

local function hostOf(u)
    return (tostring(u or ""):match("^%a+://([^/?#]+)") or ""):gsub("^[^@]*@", ""):gsub(":%d+$", ""):lower()
end

--- Is `u` one of the built-in libraries (asked as KOReader), or a site
--- someone added (asked as a browser)?
function OPDS.isBuiltin(u)
    local h = hostOf(u)
    if h == "" then return false end
    if h == hostOf(OPDS.gutendex) or h:find("archive%.org$") then return true end
    for id, src in pairs(OPDS.sources) do
        if not tostring(id):match("^user_") then
            for _, k in ipairs({ "home", "search", "newest" }) do
                if src[k] and hostOf(src[k]) == h then return true end
            end
        end
    end
    return false
end

local function acceptLanguage()
    local lang = tostring(G_reader_settings and G_reader_settings:readSetting("language") or "en"):gsub("_", "-")
    if lang == "" or lang == "C" then lang = "en" end
    local base = lang:match("^(%a+)") or "en"
    if base == lang then return lang .. ",en;q=0.8" end
    return lang .. "," .. base .. ";q=0.9,en;q=0.8"
end

--- The headers to send to `u`: KOReader's for a built-in library, a
--- browser's for anything else. `accept`: what we want back.
function OPDS.headersFor(u, accept)
    if OPDS.isBuiltin(u) then
        return {
            ["Accept"] = accept or "application/atom+xml, application/xml",
            ["Accept-Encoding"] = "identity",
            ["User-Agent"] = "KOReader Bookdrop/0.6",
        }
    end
    return {
        ["User-Agent"] = OPDS.BROWSER_UA,
        ["Accept"] = accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Accept-Language"] = acceptLanguage(),
        ["Accept-Encoding"] = "identity",
        ["Upgrade-Insecure-Requests"] = "1",
    }
end

-- Set-Cookie headers (luasocket joins several with ", ") into the jar
-- { name = value }. Attributes (Path, Expires...) are left out.
local function keepCookies(jar, header)
    if type(header) ~= "string" then return end
    header = header:gsub(",%s*([%w!#$%%&'*+%-.^_`|~]+)=", "\n%1=")
    for line in header:gmatch("[^\n]+") do
        local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
        if name and not ({ path = 1, domain = 1, expires = 1, ["max-age"] = 1 })[name:lower()] then
            jar[name] = value
        end
    end
end

local function cookieHeader(jar)
    local parts = {}
    for k, v in pairs(jar) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, "; ") or nil
end

--- Why a site refused us, when it's bot protection or a limit: a short
--- reason for the store's "Couldn't reach" line, else nil.
function OPDS.blockReason(code, headers, body)
    code = tonumber(code) or 0
    headers = headers or {}
    local server = tostring(headers.server or ""):lower()
    local b = tostring(body or ""):sub(1, 6000):lower()
    local refused = code == 403 or code == 503 or code == 429
    if headers["cf-mitigated"] or b:find("cf_chl_", 1, true) or b:find("challenge-platform", 1, true)
        or (server:find("cloudflare", 1, true) and refused
            and (b:find("just a moment", 1, true) or b:find("attention required", 1, true))) then
        return "blocks apps: Cloudflare check"
    end
    if server:find("ddos-guard", 1, true) or b:find("ddos-guard", 1, true) then
        return "blocks apps: DDoS-Guard check"
    end
    if refused and (b:find("captcha", 1, true) or b:find("are you a robot", 1, true)) then
        return "blocks apps: asks for a captcha"
    end
    if code == 429 then return "too many requests: try again later" end
end

-- One HTTP GET, returning the body or nil, why. Refuses answers over
-- max_response_bytes (6 MB) so a huge page can't run the Kindle out of
-- memory. Also used for Gutendex's JSON (M.gutenbergCounts in bos_store)
-- and for the sites people add (bos_store_libs, bos_store_web): those are
-- asked as a browser, redirects followed here (up to 8) with their cookies.
-- `wait`: { block, total } seconds for a slow server (Gutendex), else
-- KOReader's usual large-request timeouts. "wantread"/"wantwrite" from the
-- secure connection mean the wait ran out: reported as "too slow to answer".
local function slowWords(why)
    why = tostring(why or "")
    if why == "wantread" or why == "wantwrite" or why == "timeout" or why:find("timed? ?out") then
        return "too slow to answer"
    end
    return why
end

local function requestPayload(request_url, accept, wait)
    local builtin = OPDS.isBuiltin(request_url)
    local jar, url_now, referer = {}, request_url, nil
    local userinfo = request_url:match("^%a+://([^/@]*@)")
    for hop = 1, 8 do
        local chunks, received, too_large = {}, 0, false
        local sink = function(chunk)
            if chunk then
                received = received + #chunk
                if received > OPDS.max_response_bytes then
                    too_large = true
                    return nil, "response is too large"
                end
                chunks[#chunks + 1] = chunk
            end
            return 1
        end
        local headers = OPDS.headersFor(url_now, accept)
        if not builtin then
            headers["Cookie"] = cookieHeader(jar)
            headers["Referer"] = referer
        end
        if wait then
            socketutil:set_timeout(wait[1], wait[2])
        else
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        end
        local ok, code, rheaders, status = http.request{
            url = url_now,
            method = "GET",
            redirect = builtin,
            headers = headers,
            sink = sink,
        }
        socketutil:reset_timeout()
        if too_large then return nil, "OPDS response exceeded 6 MiB" end
        if not ok then return nil, slowWords(code or status or "no answer") end
        code = tonumber(code)
        rheaders = type(rheaders) == "table" and rheaders or {}
        local location = rheaders.location
        if not builtin and code and code >= 300 and code < 400 and location then
            keepCookies(jar, rheaders["set-cookie"])
            referer = url_now
            local next_url = url.absolute(url_now, location)
            -- (luasocket drops a user:password@ on a redirect: kept for the same host)
            if userinfo and not next_url:match("^%a+://[^/@]*@") and hostOf(next_url) == hostOf(request_url) then
                next_url = next_url:gsub("^(%a+://)", "%1" .. userinfo)
            end
            url_now = next_url
        else
            local payload = table.concat(chunks)
            if code ~= 200 then
                return nil, (not builtin and OPDS.blockReason(code, rheaders, payload)) or status or ("HTTP " .. tostring(code))
            end
            if not builtin then
                local why = OPDS.blockReason(code, rheaders, #payload < 20000 and payload or "")
                if why then return nil, why end
            end
            if payload == "" then return nil, "Catalog returned an empty response" end
            return payload
        end
    end
    return nil, "too many redirects"
end

local function requestXml(request_url)
    local payload, err = requestPayload(request_url, "application/atom+xml, application/xml;q=0.9, */*;q=0.8")
    if not payload then return nil, err end
    local parsed_ok, document = pcall(parseXml, payload)
    if not parsed_ok or type(document) ~= "table" or document.name ~= "feed" then
        return nil, "Server did not return an OPDS feed"
    end
    return document
end

-- A short id for a book from its feed id ("gutenberg-123456789"), used as
-- its cover's file name and to spot the same book twice.
local function stableId(source_id, raw_id)
    local hash = 5381
    for character_number = 1, #raw_id do
        hash = (hash * 33 + raw_id:byte(character_number)) % 2147483647
    end
    return source_id .. "-" .. tostring(hash)
end

local function absolute(base_url, href)
    if not href or href == "" then return nil end
    local resolved = url.absolute(base_url, href)
    return resolved:gsub("^http://gallica%.bnf%.fr", "https://gallica.bnf.fr")
end

-- Which file type a download link is, from its MIME type, then the end of
-- its address, then its title. nil = not a type we offer (skipped).
local function extensionFromLink(link)
    local mime = tostring(link.attributes.type or ""):lower()
    local href = tostring(link.attributes.href or ""):lower():gsub("[?#].*$", "")
    local title = tostring(link.attributes.title or ""):lower()
    if mime:find("epub", 1, true) then return "epub" end
    if mime:find("pdf", 1, true) then return "pdf" end
    if mime:find("djvu", 1, true) then return "djvu" end
    if mime:find("comicbook", 1, true) or href:match("%.cbz$") then return "cbz" end
    if mime:find("text/plain", 1, true) or href:match("%.txt$") then return "txt" end
    if mime:find("mobipocket", 1, true) then
        if href:match("%.azw3$") or title:find("azw3", 1, true) then return "azw3" end
        return "mobi"
    end
    return nil
end

-- When a feed lists several files of one type (Gutenberg's "EPUB3",
-- "EPUB (no images)", ...), the highest score wins: recommended, then
-- EPUB3, then with images.
local function acquisitionScore(link, extension)
    local title = tostring(link.attributes.title or ""):lower()
    local score = 1
    if title:find("recommended", 1, true) then score = score + 8 end
    if title:find("epub3", 1, true) then score = score + 6 end
    if title:find("images", 1, true) and not title:find("no images", 1, true) then score = score + 4 end
    if title:find("no images", 1, true) then score = score - 1 end
    if extension == "epub" then score = score + 2 end
    return score
end

local function acquisitionAllowed(extension, formats)
    if type(formats) ~= "table" then return true end
    if extension == "azw3" then return formats.mobi == true end
    return formats[extension] == true
end

-- A book's downloads: its rel="...acquisition" links, one per file type
-- (the best by acquisitionScore), in FORMAT_ORDER.
local function collectAcquisitions(entry, base_url, formats)
    local selected = {}
    for _, link in ipairs(children(entry, "link")) do
        local relation = tostring(link.attributes.rel or "")
        local extension = relation:find("acquisition", 1, true) and extensionFromLink(link)
        local href = absolute(base_url, link.attributes.href)
        if extension and href and acquisitionAllowed(extension, formats) then
            local candidate = {
                type = link.attributes.type,
                format = FORMAT_LABELS[extension],
                extension = extension,
                url = href,
                size = tonumber(link.attributes.length),
                source = "catalog",
                label = link.attributes.title,
                score = acquisitionScore(link, extension),
            }
            if not selected[extension] or candidate.score > selected[extension].score then
                selected[extension] = candidate
            end
        end
    end
    local acquisitions = {}
    for _, extension in ipairs(FORMAT_ORDER) do
        if selected[extension] then acquisitions[#acquisitions + 1] = selected[extension] end
    end
    return acquisitions
end

local function availableFormats(acquisitions)
    local formats = {}
    for _, acquisition in ipairs(acquisitions or {}) do formats[#formats + 1] = acquisition.format end
    return table.concat(formats, " · ")
end

local function hasAllowedAcquisition(acquisitions, formats)
    if type(formats) ~= "table" then return #acquisitions > 0 end
    for _, acquisition in ipairs(acquisitions) do
        if acquisitionAllowed(acquisition.extension, formats) then return true end
    end
    return false
end

local function gutenbergFormatAllowed(formats)
    if type(formats) ~= "table" then return true end
    return formats.epub == true or formats.mobi == true or formats.txt == true
end

local function entryCategories(entry)
    local categories = {}
    for _, category in ipairs(children(entry, "category")) do
        local term = category.attributes.label or category.attributes.term
        if term and term ~= "" then categories[#categories + 1] = term end
    end
    return table.concat(categories, " · ")
end

-- Guesses Fiction / Non-fiction / Comic / Magazine from a book's subjects,
-- for the storefront's category shelves (matchesContent drops the rest).
local function contentType(subjects)
    local value = tostring(subjects or ""):lower()
    if value:find("comic", 1, true) then return "Comic" end
    if value:find("magazine", 1, true) or value:find("periodical", 1, true) then return "Magazine" end
    if value:find("fiction", 1, true) or value:find("novela", 1, true)
        or value:find("cuento", 1, true) then return "Book (fiction)" end
    return "Book (non-fiction)"
end

local function matchesContent(book, requested)
    if not requested or requested == "" or not book.subjects or book.subjects == "" then return true end
    local actual = tostring(book.content_type or ""):lower()
    if requested == "book_fiction" then return actual == "book (fiction)" end
    if requested == "book_nonfiction" then return actual == "book (non-fiction)" end
    if requested == "book_comic" then return actual == "comic" end
    if requested == "magazine" then return actual == "magazine" end
    return true
end

local LANGUAGE_ALIASES = {
    en = "en", eng = "en", english = "en",
    es = "es", spa = "es", spanish = "es",
    fr = "fr", fre = "fr", fra = "fr", french = "fr",
    de = "de", ger = "de", deu = "de", german = "de",
    it = "it", ita = "it", italian = "it",
    pt = "pt", por = "pt", portuguese = "pt",
}

local function normalizedLanguage(language)
    local first = tostring(language or ""):lower():match("^%s*([%a]+)")
    return first and (LANGUAGE_ALIASES[first] or first) or nil
end

-- ONE FEED ENTRY -> ONE STORE BOOK. Reads the title, id, authors,
-- description, cover (thumbnail, else full image), subjects, language, year
-- and downloads. Returns nil (skipped) when it has no title/id, no download
-- and no detail page, a language other than the one filtered for, no file
-- of a ticked type, or the wrong content type for a category shelf.
-- Gutenberg's search feed has no downloads: its detail_url is kept and
-- hydrate() reads the files when the book is opened.
local function entryToBook(entry, base_url, source_id, source, filters)
    local title = nodeText(child(entry, "title"))
    local raw_id = nodeText(child(entry, "id", "dc:identifier", "dcterms:identifier"))
    if title == "" or raw_id == "" then return nil end

    local detail_url
    local cover_url, fallback_cover
    for _, link in ipairs(children(entry, "link")) do
        local relation = tostring(link.attributes.rel or "")
        local href = absolute(base_url, link.attributes.href)
        if href and not href:match("^https?://") then href = nil end
        if relation:find("image/thumbnail", 1, true) then
            cover_url = href
        elseif relation:find("/image", 1, true) then
            fallback_cover = href
        elseif source_id == "gutenberg" and relation == "subsection"
            and href and href:match("/ebooks/%d+%.opds") then
            detail_url = href
        end
    end

    local author_names = {}
    for _, author in ipairs(children(entry, "author")) do
        local name = nodeText(child(author, "name"))
        if name ~= "" then author_names[#author_names + 1] = name end
    end
    local description = nodeText(child(entry, "summary", "content"))
    local author = table.concat(author_names, ", ")
    if author == "" and source_id == "gutenberg" and description ~= "" then
        author, description = description, ""
    end

    local acquisitions = collectAcquisitions(entry, base_url)
    if #acquisitions == 0 and not detail_url then return nil end
    if source_id == "gutenberg" and detail_url
        and not gutenbergFormatAllowed(filters and filters.formats) then return nil end
    if #acquisitions > 0 and filters and type(filters.formats) == "table"
        and not hasAllowedAcquisition(acquisitions, filters.formats) then return nil end
    local language = nodeText(child(entry, "dcterms:language", "dc:language", "language"))
    if language == "" then language = source.default_language or "" end
    if filters and filters.language and normalizedLanguage(language) ~= filters.language then return nil end

    local subjects = entryCategories(entry)
    local published = nodeText(child(entry, "published", "dc:issued", "dcterms:issued"))
    local book = {
        id = stableId(source_id, raw_id),
        provider = source_id,
        provider_id = raw_id,
        detail_url = detail_url,
        title = title,
        author = author ~= "" and author or "Unknown author",
        description = description,
        language = language,
        published_date = published,
        year = published:match("(%d%d%d%d)"),
        publisher = nodeText(child(entry, "dc:publisher", "dcterms:publisher", "publisher")),
        subjects = subjects,
        rights = nodeText(child(entry, "rights", "dc:rights", "dcterms:rights")),
        size = nodeText(child(entry, "dcterms:extent")),
        format = acquisitions[1] and acquisitions[1].format or "EBOOK",
        available_formats = availableFormats(acquisitions),
        allowed_formats = filters and filters.formats,
        content_type = contentType(subjects),
        source = source.name,
        cover_url = cover_url or fallback_cover,
        cover_fallback_url = cover_url and fallback_cover or nil,
        acquisitions = acquisitions,
    }
    if source_id == "gutenberg" and not book.cover_url then
        local ebook_number = (detail_url or raw_id):match("/ebooks/(%d+)")
        if ebook_number then
            book.cover_url = "https://www.gutenberg.org/cache/epub/" .. ebook_number
                .. "/pg" .. ebook_number .. ".cover.medium.jpg"
        end
    end
    if source_id == "gutenberg" and #acquisitions == 0 then
        book.available_formats = "EPUB · MOBI · TXT"
        if filters and filters.formats and filters.formats.epub then
            book.format = "EPUB"
        elseif filters and filters.formats and filters.formats.mobi then
            book.format = "MOBI"
        elseif filters and filters.formats and filters.formats.txt then
            book.format = "TXT"
        end
    end
    return matchesContent(book, filters and filters.content) and book or nil
end

-- A whole feed -> books, total count, and the next page's address
-- (rel="next"), if any.
local function feedInfo(document, request_url, source_id, source, filters)
    local books = {}
    for _, entry in ipairs(children(document, "entry")) do
        local book = entryToBook(entry, request_url, source_id, source, filters)
        if book then books[#books + 1] = book end
    end
    local total = tonumber(nodeText(child(document, "opensearch:totalResults"))) or #books
    local next_url
    for _, link in ipairs(children(document, "link")) do
        if link.attributes.rel == "next" then
            next_url = absolute(request_url, link.attributes.href)
            break
        end
    end
    return books, total, next_url
end

-- Which URL to ask for, given what was typed, the page and the sort:
--   * Gallica with a query: its own SRU expression, every word required
--     (gallica all "word" and ...) and EPUBs only. (A plain query to Gallica
--     actually goes through searchGallica below; this covers its home.)
--   * any query: the `search` template;
--   * no query and the library has a URL named after the sort ("newest"):
--     that URL;
--   * otherwise `home`.
local function sourceUrl(source_id, source, query, page, filters)
    local escaped_query = url.escape(query or "")
    if source_id == "gallica" and query and query:match("%S") then
        local clauses = {}
        for word in query:gsub('"', ""):gmatch("%S+") do
            clauses[#clauses + 1] = '(gallica all "' .. word .. '")'
        end
        local expression = table.concat(clauses, " and ")
            .. ' and dc.formatspecific all "epub"'
        return string.format(source.search, url.escape(expression))
    end
    if query and query:match("%S") then
        if source.direct_page then return string.format(source.search, escaped_query, page) end
        return string.format(source.search, escaped_query)
    end
    if filters and source[filters.sort] then
        return source[filters.sort]
    end
    if source.direct_page then return string.format(source.home, page) end
    return source.home
end

-- textos.info's multi-word search occasionally omits books whose titles are an
-- obvious match (for example, "el gato" does not return "El Gato Negro", while
-- "gato" does).  Keep the catalog as the source of truth, but supplement a bad
-- multi-word response with a small number of single-term catalog searches.
local SEARCH_STOP_WORDS = {
    a = true, al = true, de = true, del = true, el = true, en = true,
    la = true, las = true, los = true, un = true, una = true, y = true,
}

local function normalizeSearchText(value)
    value = tostring(value or "")
    local replacements = {
        { "[ÁÀÂÄÃáàâäã]", "a" }, { "[ÉÈÊËéèêë]", "e" },
        { "[ÍÌÎÏíìîï]", "i" }, { "[ÓÒÔÖÕóòôöõ]", "o" },
        { "[ÚÙÛÜúùûü]", "u" }, { "[Ññ]", "n" }, { "[Çç]", "c" },
    }
    for _, replacement in ipairs(replacements) do
        value = value:gsub(replacement[1], replacement[2])
    end
    return value:lower():gsub("[^%w]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function significantSearchTerms(query)
    local terms, seen = {}, {}
    for term in normalizeSearchText(query):gmatch("%S+") do
        if #term > 1 and not SEARCH_STOP_WORDS[term] and not seen[term] then
            seen[term] = true
            terms[#terms + 1] = term
            if #terms == 3 then break end
        end
    end
    return terms
end

local function titleContainsTerms(book, terms)
    if #terms == 0 then return false end
    local title = " " .. normalizeSearchText(book.title) .. " "
    for _, term in ipairs(terms) do
        if not title:find(" " .. term .. " ", 1, true) then return false end
    end
    return true
end

local function mergeBooks(target, additions, seen)
    for _, book in ipairs(additions or {}) do
        local key = tostring(book.provider_id or book.id)
        if not seen[key] then
            seen[key] = true
            target[#target + 1] = book
        end
    end
end

local function rankTextosBooks(books, query, terms)
    local phrase = normalizeSearchText(query)
    for position, book in ipairs(books) do
        local title = normalizeSearchText(book.title)
        book._textos_search_position = position
        if title == phrase then
            book._textos_search_rank = 0
        elseif phrase ~= "" and (title .. " "):find(phrase .. " ", 1, true) == 1 then
            book._textos_search_rank = 1
        elseif titleContainsTerms(book, terms) then
            book._textos_search_rank = 2
        else
            book._textos_search_rank = 3
        end
    end
    table.sort(books, function(left, right)
        if left._textos_search_rank ~= right._textos_search_rank then
            return left._textos_search_rank < right._textos_search_rank
        end
        return left._textos_search_position < right._textos_search_position
    end)
    for _, book in ipairs(books) do
        book._textos_search_rank = nil
        book._textos_search_position = nil
    end
end

local function textosAuthorBooks(query, source, filters)
    local search_url = "https://www.textos.info/buscar/" .. url.escape(query)
    local html = requestPayload(search_url, "text/html, application/xhtml+xml")
    if not html then return {} end
    local terms = significantSearchTerms(query)
    local books, seen_slugs, candidates = {}, {}, 0
    for slug, label in html:gmatch('<h3[^>]*>%s*<a%s+href="%.?/([^"/?#]+)"[^>]*>(.-)</a>') do
        label = decodeEntities(label:gsub("<.->", " "):gsub("%s+", " "))
        local normalized_label = normalizeSearchText(label)
        local matches = #terms > 0
        for _, term in ipairs(terms) do
            if not normalized_label:find(term, 1, true) then matches = false break end
        end
        if matches and not seen_slugs[slug] then
            seen_slugs[slug] = true
            candidates = candidates + 1
            local author_url = "https://www.textos.info/autor.atom&author=" .. url.escape(slug)
            local document = requestXml(author_url)
            if document then
                local author_books = feedInfo(document, author_url, "textos", source, filters)
                for _, book in ipairs(author_books) do books[#books + 1] = book end
            end
            if candidates == 3 then break end
        end
    end
    return books
end

local function gallicaSearchUrl(source, field, query)
    local cleaned = tostring(query or ""):gsub('["\\]', " "):gsub("%s+", " ")
        :gsub("^%s+", ""):gsub("%s+$", "")
    local expression = field .. ' all "' .. cleaned
        .. '" and dc.formatspecific all "epub"'
    return string.format(source.search, url.escape(expression))
end

local function pagedFeed(first_url, page, source_id, source, filters)
    local request_url, document, err = first_url
    local books, total, next_url
    for page_number = 1, page do
        document, err = requestXml(request_url)
        if not document then return nil, err end
        books, total, next_url = feedInfo(document, request_url, source_id, source, filters)
        if page_number < page then
            if not next_url then return {}, total, nil end
            request_url = next_url
        end
    end
    return books, total, next_url
end

local function searchGallica(source, query, page, filters)
    if filters and type(filters.formats) == "table" and not filters.formats.epub then
        return { books = {}, total = 0, page = page, has_previous = page > 1, has_next = false }
    end
    local merged, seen, totals, has_next, errors = {}, {}, {}, false, {}
    -- (ShelfTechUI: and every field at once, for a title and an author
    -- together: "dracula stoker" is neither a title nor an author)
    local fields = { "dc.title", "dc.creator" }
    if tostring(query):match("%S+%s+%S+") then fields[#fields + 1] = "gallica" end
    for _, field in ipairs(fields) do
        local request_url = gallicaSearchUrl(source, field, query)
        local books, total, next_url = pagedFeed(request_url, page, "gallica", source, filters)
        if books then
            totals[#totals + 1] = tonumber(total) or #books
            mergeBooks(merged, books, seen)
            has_next = has_next or next_url ~= nil
        else
            errors[#errors + 1] = tostring(total)
        end
    end
    if #totals == 0 then return nil, table.concat(errors, "\n") end
    local total = #merged
    for _, candidate_total in ipairs(totals) do total = math.max(total, candidate_total) end
    return {
        books = merged,
        total = total,
        page = page,
        has_previous = page > 1,
        has_next = has_next,
    }
end

-- Search one OPDS library. Steps:
--   1. Gallica with a query -> searchGallica (title and author searched
--      separately, results combined).
--   2. Otherwise fetch sourceUrl() and turn the feed into books.
--   3. textos.info only: its multi-word search misses obvious titles, so if
--      no title holds every word, each word is searched on its own and the
--      results merged; books by an author of that name are added too
--      (textosAuthorBooks). Both are re-ranked by rankTextosBooks.
--   4. Page 2+ on a library without `direct_page`: follow rel="next" links.
-- What comes back is still filtered and sorted by the store afterwards
-- (matchesQuery / sortBooks), so this only has to find candidates.
-- GUTENBERG THROUGH GUTENDEX. Project Gutenberg's own search is often
-- overloaded (it answers 503, or a notice instead of results: AI scrapers
-- hammer it), so when it fails the same catalogue is asked through Gutendex
-- (gutendex.com, an open JSON copy of it, also used for download counts).
-- The books' files still come from gutenberg.org (its file servers are
-- separate from its search). 32 books a page, most downloaded first.
-- The address can be pointed elsewhere for tests with STUI_GUTENDEX.
OPDS.gutendex = os.getenv("STUI_GUTENDEX") or "https://gutendex.com"

local GUTENDEX_FORMATS = {
    { mime = "application/epub+zip", extension = "epub" },
    { mime = "application/x-mobipocket-ebook", extension = "mobi" },
    { mime = "text/plain", extension = "txt" },
}

local function searchGutendex(source, query, page, filters)
    local parts = { "page=" .. tostring(page) }
    if query and query:match("%S") then parts[#parts + 1] = "search=" .. url.escape(query) end
    if filters and filters.language and filters.language ~= "" then
        parts[#parts + 1] = "languages=" .. url.escape(filters.language)
    end
    if filters and filters.sort == "newest" then parts[#parts + 1] = "sort=descending"
    elseif filters and filters.sort == "oldest" then parts[#parts + 1] = "sort=ascending" end
    -- (Gutendex is often slow to start answering: 15 s to begin, 35 s in all,
    -- inside the store's 45 s per library)
    local payload, err = requestPayload(OPDS.gutendex .. "/books/?" .. table.concat(parts, "&"), "application/json", { 15, 35 })
    if not payload then return nil, "Gutendex: " .. tostring(err) end
    local ok, data = pcall(function() return require("rapidjson").decode(payload) end)
    if not ok or type(data) ~= "table" or type(data.results) ~= "table" then
        return nil, "Gutendex: unreadable answer"
    end
    local books = {}
    for _, r in ipairs(data.results) do
        local n = tostring(r.id or "")
        local formats = type(r.formats) == "table" and r.formats or {}
        local acquisitions = {}
        for _, f in ipairs(GUTENDEX_FORMATS) do
            for mime, href in pairs(formats) do
                if type(href) == "string" and tostring(mime):find(f.mime, 1, true) == 1
                    and not href:match("%.zip$") and not acquisitions[f.extension] then
                    acquisitions[f.extension] = { type = mime, format = FORMAT_LABELS[f.extension],
                        extension = f.extension, url = href, source = "catalog" }
                end
            end
        end
        local list = {}
        for _, ext in ipairs(FORMAT_ORDER) do if acquisitions[ext] then list[#list + 1] = acquisitions[ext] end end
        local names = {}
        for _, a in ipairs(type(r.authors) == "table" and r.authors or {}) do
            if type(a) == "table" and a.name then names[#names + 1] = a.name end
        end
        local subjects = table.concat(type(r.subjects) == "table" and r.subjects or {}, " · ")
        if n ~= "" and r.title and #list > 0 then
            books[#books + 1] = {
                id = "gutenberg-gd-" .. n,
                provider = "gutenberg",
                provider_id = n,
                detail_url = "https://www.gutenberg.org/ebooks/" .. n,
                title = r.title,
                author = table.concat(names, ", "),
                language = type(r.languages) == "table" and r.languages[1] or "",
                subjects = subjects,
                content_type = contentType(subjects),
                downloads = tonumber(r.download_count),
                source = source.name,
                format = list[1].format,
                available_formats = availableFormats(list),
                allowed_formats = filters and filters.formats,
                cover_url = type(formats["image/jpeg"]) == "string" and formats["image/jpeg"]
                    or ("https://www.gutenberg.org/cache/epub/" .. n .. "/pg" .. n .. ".cover.medium.jpg"),
                acquisitions = list,
            }
        end
    end
    return {
        books = books,
        total = tonumber(data.count) or #books,
        page = page,
        has_previous = page > 1,
        has_next = data.next ~= nil and data.next ~= require("rapidjson").null,
    }
end

function OPDS:searchSource(source_id, query, page, filters)
    local source = self.sources[source_id]
    if not source then return nil, "Unknown OPDS source" end
    page = math.max(1, tonumber(page) or 1)
    if source_id == "gallica" and query and query:match("%S") then
        return searchGallica(source, query, page, filters)
    end
    local request_url = sourceUrl(source_id, source, query, page, filters)
    local document, err = requestXml(request_url)
    if not document and source_id == "gutenberg" then
        -- (its search failed: the same catalogue through Gutendex)
        local result, err2 = searchGutendex(source, query, page, filters)
        if result then return result end
        require("logger").warn("ShelfTechUI: store, Gutenberg:", err, "/", err2)
        return nil, source.name .. ": " .. tostring(err) .. ", Gutendex too"
    end
    if not document then return nil, source.name .. ": " .. tostring(err) end

    local books, total, next_url = feedInfo(document, request_url, source_id, source, filters)
    if source_id == "textos" and page == 1 and query and query:match("%S") then
        local terms = significantSearchTerms(query)
        local word_count = 0
        for _ in normalizeSearchText(query):gmatch("%S+") do word_count = word_count + 1 end
        local has_title_match = false
        for _, book in ipairs(books) do
            if titleContainsTerms(book, terms) then
                has_title_match = true
                break
            end
        end
        if word_count > 1 and #terms > 0 and not has_title_match then
            local seen = {}
            for _, book in ipairs(books) do
                seen[tostring(book.provider_id or book.id)] = true
            end
            for _, term in ipairs(terms) do
                local fallback_url = string.format(source.search, url.escape(term))
                local fallback_document = requestXml(fallback_url)
                if fallback_document then
                    local fallback_books = feedInfo(
                        fallback_document, fallback_url, source_id, source, filters)
                    mergeBooks(books, fallback_books, seen)
                end
            end
            rankTextosBooks(books, query, terms)
            total = #books
        end
        local seen = {}
        for _, book in ipairs(books) do seen[tostring(book.provider_id or book.id)] = true end
        local author_books = textosAuthorBooks(query, source, filters)
        local before = #books
        mergeBooks(books, author_books, seen)
        if #books > before then
            rankTextosBooks(books, query, terms)
            total = #books
        end
    end
    if not source.direct_page and page > 1 then
        for page_number = 2, page do
            if not next_url then
                books = {}
                break
            end
            request_url = next_url
            document, err = requestXml(request_url)
            if not document then return nil, source.name .. ": " .. tostring(err) end
            books, total, next_url = feedInfo(document, request_url, source_id, source, filters)
        end
    end
    return {
        books = books,
        total = total,
        page = page,
        has_previous = page > 1,
        has_next = next_url ~= nil or (source.direct_page and #books >= self.page_size),
    }
end

-- When a book is opened: if it has no downloads yet, its detail feed is
-- read and the best file of each type is kept, along with anything the
-- search result left out (description, cover...).
function OPDS:hydrate(book)
    if not book then return nil, "Book is missing" end
    if book.acquisitions and #book.acquisitions > 0 then return book end
    if not book.detail_url then return nil, "This catalog did not provide a book detail feed" end
    local source = self.sources[book.provider]
    if not source then return nil, "Unknown OPDS source" end
    local document, err = requestXml(book.detail_url)
    if not document then return nil, err end
    local books = feedInfo(document, book.detail_url, book.provider, source, {})
    if #books == 0 then return nil, "No compatible public file was listed" end

    local selected = {}
    for _, edition in ipairs(books) do
        for _, acquisition in ipairs(edition.acquisitions or {}) do
            local existing = selected[acquisition.extension]
            if not existing or (acquisition.score or 0) > (existing.score or 0) then
                selected[acquisition.extension] = acquisition
            end
        end
        for key, value in pairs(edition) do
            if (book[key] == nil or book[key] == "") and value ~= nil and value ~= "" then
                book[key] = value
            end
        end
    end
    book.acquisitions = {}
    for _, extension in ipairs(FORMAT_ORDER) do
        if selected[extension] then book.acquisitions[#book.acquisitions + 1] = selected[extension] end
    end
    book.available_formats = availableFormats(book.acquisitions)
    if book.acquisitions[1] then
        book.format = book.acquisitions[1].format
        local size = tonumber(book.acquisitions[1].size)
        if size then book.size = string.format("%.1f MB", size / 1024 / 1024) end
    end
    return book
end

-- (for ShelfTechUI's own libraries, added by address: bos_store_libs)
OPDS._requestXml, OPDS._requestPayload, OPDS._feedInfo, OPDS._pagedFeed = requestXml, requestPayload, feedInfo, pagedFeed
OPDS._absolute, OPDS._children, OPDS._child, OPDS._nodeText, OPDS._parseXml = absolute, children, child, nodeText, parseXml

return OPDS
