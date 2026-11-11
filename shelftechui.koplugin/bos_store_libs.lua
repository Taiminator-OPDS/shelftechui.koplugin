--[[
Your own libraries in the store, added by address.

Any catalogue that speaks OPDS (the open standard e-book catalogues use: a
Calibre or Calibre-Web server, Kavita, Komga, COPS, a public library's or a
publisher's feed) can be added by the address of its catalogue. It's then
asked along with the built-in libraries when you search, and has a shelf of
its own to browse on the storefront.

  M.list()                 { { id, name, url, search, browse, on }, … }
  M.probe(url)             (blocking: run it in the background) reads the
                           catalogue: its name, how it's searched (its
                           OpenSearch link), and a feed of books to browse
  M.add(info) / M.remove(id) / M.setOn(id, on) / M.rename(id, name)
  M.register()             makes them known to Bookdrop's catalogue code
  M.search(id, query, page, filters)   one library's answer

A catalogue behind a password: put it in the address
(https://name:password@host/opds); it's kept in KOReader's settings on
this device.
--]]

local logger = require("logger")
local _ = require("gettext")

local Store = require("bos_settings_store")

local M = {}

local KEY = "store_libraries"

local function OPDS() return require("bookdrop_opds_provider") end
local function Provider() return require("bookdrop_catalog_provider") end

function M.list()
    local l = Store.get(KEY)
    return type(l) == "table" and l or {}
end

local function save(l) Store.set(KEY, l) end

function M.find(id)
    for i, lib in ipairs(M.list()) do if lib.id == id then return lib, i end end
end

--- A catalogue's address as typed, made whole.
function M.tidy(url)
    url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return nil end
    if url:match("^opds://") then url = url:gsub("^opds://", "https://") end
    if not url:match("^https?://") then url = "https://" .. url end
    return url
end

local function host(url)
    return (tostring(url):gsub("^https?://", ""):gsub("^[^/@]*@", ""):gsub("/.*$", ""))
end
M.host = host

local function isAcquisition(link)
    local rel, ty = tostring(link.attributes.rel or ""), tostring(link.attributes.type or "")
    return rel:find("opds-spec.org/acquisition", 1, true) ~= nil or ty:find("kind=acquisition", 1, true) ~= nil
end

--- Does this feed list books (not only further feeds)?
local function hasBooks(document)
    local O = OPDS()
    for _i, entry in ipairs(O._children(document, "entry")) do
        for _j, link in ipairs(O._children(entry, "link")) do
            if isAcquisition(link) and not tostring(link.attributes.type or ""):find("profile=opds-catalog", 1, true) then
                return true
            end
        end
    end
    return false
end

--- Read the catalogue at `url`. Returns { name, url, search, browse } or
--- nil and why. Blocking (network).
function M.probe(url)
    url = M.tidy(url)
    if not url then return nil, _("No address.") end
    local O = OPDS()
    local document, err = O._requestXml(url)
    if not document then return nil, tostring(err) end
    local info = { url = url, name = O._nodeText(O._child(document, "title")) }
    if info.name == "" then info.name = host(url) end
    -- how it's searched
    for _i, link in ipairs(O._children(document, "link")) do
        local rel, ty = tostring(link.attributes.rel or ""), tostring(link.attributes.type or "")
        local href = O._absolute(url, link.attributes.href)
        if rel == "search" and href then
            if ty:find("opensearchdescription", 1, true) then
                local payload = O._requestPayload(href, "application/opensearchdescription+xml, application/xml")
                if payload then
                    -- the Atom template, else any
                    local best
                    for tag in payload:gmatch("<[%w:]*Url%s[^>]*>") do
                        local t = tag:match('template%s*=%s*"([^"]+)"') or tag:match("template%s*=%s*'([^']+)'")
                        local kind = tag:match('type%s*=%s*"([^"]+)"') or tag:match("type%s*=%s*'([^']+)'") or ""
                        if t and (not best or kind:find("atom", 1, true)) then
                            best = t:gsub("&amp;", "&")
                            if kind:find("atom", 1, true) then break end
                        end
                    end
                    if best then info.search = O._absolute(href, best) end
                end
            elseif href:find("{searchTerms", 1, true) then
                info.search = href
            end
        end
    end
    -- something to browse: this feed if it lists books, else its newest /
    -- most popular / first feed of books
    if hasBooks(document) then
        info.browse = url
    else
        local candidates = {}
        local function consider(link, rank)
            local href = O._absolute(url, link.attributes.href)
            local ty = tostring(link.attributes.type or "")
            if href and href:match("^https?://") and (ty == "" or ty:find("atom", 1, true)) and not ty:find("opensearch", 1, true) then
                table.insert(candidates, { href = href, rank = rank })
            end
        end
        local function rankOf(link, title)
            local rel, ty = tostring(link.attributes.rel or ""), tostring(link.attributes.type or "")
            title = tostring(title or link.attributes.title or ""):lower()
            if rel:find("sort/new", 1, true) or title:find("new") or title:find("recent") or title:find("latest") then return 1 end
            if rel:find("sort/popular", 1, true) or rel:find("featured", 1, true) or title:find("popular") then return 2 end
            if ty:find("kind=acquisition", 1, true) then return 3 end
            return 5
        end
        for _i, link in ipairs(O._children(document, "link")) do
            local rel = tostring(link.attributes.rel or "")
            if rel ~= "self" and rel ~= "start" and rel ~= "search" and rel ~= "up" then consider(link, rankOf(link)) end
        end
        for _i, entry in ipairs(O._children(document, "entry")) do
            local title = O._nodeText(O._child(entry, "title"))
            for _j, link in ipairs(O._children(entry, "link")) do consider(link, rankOf(link, title)) end
        end
        table.sort(candidates, function(a, b) return a.rank < b.rank end)
        -- the first that really lists books (at most three looked at)
        for i = 1, math.min(3, #candidates) do
            local doc = O._requestXml(candidates[i].href)
            if doc and hasBooks(doc) then info.browse = candidates[i].href break end
        end
    end
    if not info.search and not info.browse then
        return nil, _("That address answers, but it isn't a catalogue of books (OPDS) the store can read.")
    end
    return info
end

function M.add(info)
    local l = M.list()
    for _i, lib in ipairs(l) do
        if lib.url == info.url then
            lib.name, lib.search, lib.browse, lib.on = info.name or lib.name, info.search, info.browse, true
            save(l)
            M.register()
            return lib
        end
    end
    local n = 0
    for _i, lib in ipairs(l) do n = math.max(n, tonumber(tostring(lib.id):match("(%d+)$")) or 0) end
    local lib = { id = "user_" .. (n + 1), name = info.name, url = info.url, search = info.search, browse = info.browse, on = true }
    table.insert(l, lib)
    save(l)
    M.register()
    return lib
end

function M.remove(id)
    local l = M.list()
    for i, lib in ipairs(l) do
        if lib.id == id then
            table.remove(l, i)
            save(l)
            local P = Provider()
            P.sources[id] = nil
            for k = #P.source_order, 1, -1 do if P.source_order[k] == id then table.remove(P.source_order, k) end end
            OPDS().sources[id] = nil
            return true
        end
    end
end

function M.setOn(id, on)
    local l = M.list()
    for _i, lib in ipairs(l) do if lib.id == id then lib.on = on and true or false end end
    save(l)
end

function M.rename(id, name)
    local l = M.list()
    for _i, lib in ipairs(l) do if lib.id == id and name and name:match("%S") then lib.name = name end end
    save(l)
    M.register()
end

--- The filters' libraries with yours that are on added (a copy).
function M.withLibraries(libraries)
    local out = {}
    for k, v in pairs(type(libraries) == "table" and libraries or {}) do out[k] = v end
    for _i, lib in ipairs(M.list()) do out[lib.id] = lib.on ~= false or nil end
    return out
end

local function fill(template, query, page)
    local url = require("socket.url")
    local terms = url.escape(query or "")
    local out = template:gsub("{searchTerms%??}", function() return terms end)
    local paged = out:find("{startPage", 1, true) ~= nil or out:find("{startIndex", 1, true) ~= nil
    out = out:gsub("{startPage%??}", tostring(page)):gsub("{startIndex%??}", tostring((page - 1) * 20 + 1))
        :gsub("{count%??}", "20"):gsub("{language%??}", "*"):gsub("{inputEncoding%??}", "UTF-8")
        :gsub("{outputEncoding%??}", "UTF-8"):gsub("{[%w:]+%?}", "")
    return out, paged
end
M._fill = fill

--- One of your libraries' answer: { books, total, has_next } or nil, why.
function M.search(id, query, page, filters)
    local lib = M.find(id)
    if not lib then return nil, "Unknown library" end
    local O = OPDS()
    page = math.max(1, tonumber(page) or 1)
    local source = { name = lib.name }
    local books, total, next_url
    if query and query:match("%S") then
        if not lib.search then return { books = {}, total = 0, has_next = false } end
        local first, paged = fill(lib.search, query, page)
        if paged then
            local document, err = O._requestXml(first)
            if not document then return nil, lib.name .. ": " .. tostring(err) end
            books, total, next_url = O._feedInfo(document, first, id, source, filters)
        else
            local err
            books, total, next_url = O._pagedFeed(first, page, id, source, filters)
            if not books then return nil, lib.name .. ": " .. tostring(total or err) end
        end
    else
        if not lib.browse then return { books = {}, total = 0, has_next = false } end
        books, total, next_url = O._pagedFeed(lib.browse, page, id, source, filters)
        if not books then return nil, lib.name .. ": " .. tostring(total) end
    end
    for _i, b in ipairs(books) do b.provider = id end
    return { books = books, total = total or #books, has_next = next_url ~= nil }
end

--- Make your libraries known to Bookdrop's catalogue code (names, order,
--- who answers for them, and book pages).
function M.register()
    local okP, P = pcall(Provider)
    if not okP then return end
    local O = OPDS()
    for _i, lib in ipairs(M.list()) do
        if not P.sources[lib.id] then table.insert(P.source_order, lib.id) end
        P.sources[lib.id] = lib.name
        O.sources[lib.id] = { name = lib.name, home = lib.browse or lib.url }
    end
    if not P._stui_libs then
        P._stui_libs = true
        local orig = P.searchSource
        P.searchSource = function(self, id, query, page, filters)
            if tostring(id):match("^user_%d+$") then
                local ok, res, err = pcall(M.search, id, query, page, filters)
                if not ok then logger.warn("ShelfTechUI: store, your library:", res) return nil, tostring(res) end
                return res, err
            end
            return orig(self, id, query, page, filters)
        end
    end
end

return M
