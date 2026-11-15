--[[
Hardcover (hardcover.app): your shelves, your friends' reading and what
readers say about a book, on the device. This is the part that talks to
Hardcover and remembers things; the screens are bos_hardcover_ui.

Signing in, two ways:
  * a link code (as a Kindle links Goodreads): the device shows a code and a
    QR code, you approve on hardcover.app/link on a phone. This needs an app
    ID from Hardcover (Settings → Connect → Hardcover → App ID); with one,
    it's the way offered.
  * an API key from hardcover.app, pasted into Transfer's page from a phone
    or a computer (or typed here).

Everything that touches the network runs in a background process
(bos_store's Async): the screen never waits on Hardcover.

  M.signedIn()                         → true | false
  M.user()                             → { id, username, name } | nil
  M.setKey(token, cb)                  a pasted API key: checked, then kept
  M.link.start(cb) / M.link.poll(cb)   the link code
  M.signOut()

  M.shelf(status, cb)       your books of a status (1 want, 2 reading, 3 read)
  M.friends(cb)             what the people you follow are reading
  M.trending(cb)            popular this month
  M.search(q, cb)
  M.book(id, cb)            a book: details, your entry, quotes, reviews
  M.goal(cb)                this year's reading goal

  M.setStatus(book_id, status, cb)
  M.rate(user_book_id, rating, cb)
  M.quote(book_id, text, cb)           a highlight, as a quote
  M.progress(file, percent)            where you are in a linked book

  M.linkFor(file) / M.setLink(file, book)   which Hardcover book a file is
  M.match(title, author, cb)                the likeliest book for a file

cb(data) on success, cb(nil, why) otherwise. `why` is a short sentence for
the reader.
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local M = { link = {} }

local API = "https://api.hardcover.app"
local SCOPES = "read:me:content read:catalog read:library read:journal read:social read:users read:goals write:library"
M.KEY_URL = "https://hardcover.app/account/api/keys/new?scope=" .. SCOPES:gsub(" ", "+")

-- ---------------------------------------------------------------- what's kept

local settings
local function store()
    if not settings then settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/stui_hardcover.lua") end
    return settings
end
local function get(k, default)
    local v = store():readSetting(k)
    if v == nil then return default end
    return v
end
local function set(k, v)
    if v == nil then store():delSetting(k) else store():saveSetting(k, v) end
    store():flush()
end
M.get, M.set = get, set

--- (for tests: another address for the API)
function M.base() return os.getenv("STUI_HC_API") or get("api_base") or API end

--- Hardcover's app ID for ShelfTechUI (link codes need one). None is built
--- in yet; one can be entered in Settings.
function M.clientId()
    local id = get("client_id")
    return type(id) == "string" and id ~= "" and id or nil
end

function M.signedIn() return type(get("token")) == "string" and get("token") ~= "" end
function M.user() return get("user") end

local function connected()
    local ok, on = pcall(function() return require("ui/network/manager"):isConnected() end)
    return ok and on
end
M.connected = connected

-- ---------------------------------------------------------------- the wire

local function nulls(v, null)
    if type(v) ~= "table" then return v end
    for k, x in pairs(v) do
        if x == null then v[k] = nil elseif type(x) == "table" then nulls(x, null) end
    end
    return v
end

--- One HTTP request, here and now (so: only in a background process).
--- Returns status, decoded body (or nil).
local function http(method, url, body, headers)
    local socket_http = require("socket.http")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local rapidjson = require("rapidjson")
    local sink = {}
    headers = headers or {}
    headers["User-Agent"] = "ShelfTechUI for KOReader (https://github.com/Taiminator-OPDS/shelftechui.koplugin)"
    headers["Accept"] = "application/json"
    if body then headers["Content-Length"] = tostring(#body) end
    socketutil:set_timeout(8, 20)
    local _r, code = socket_http.request{ url = url, method = method, headers = headers,
        source = body and ltn12.source.string(body) or nil, sink = socketutil.table_sink(sink) }
    socketutil:reset_timeout()
    local text = table.concat(sink)
    local ok, data = pcall(rapidjson.decode, text)
    return code, ok and nulls(data, rapidjson.null) or nil
end

local function form(t)
    local out = {}
    for k, v in pairs(t) do
        out[#out + 1] = k .. "=" .. tostring(v):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)
    end
    return table.concat(out, "&")
end

--- A GraphQL request, here and now. Returns data | nil, why, code.
local function graphql(token, query, vars)
    local rapidjson = require("rapidjson")
    local body = rapidjson.encode({ query = query, variables = vars or setmetatable({}, { __jsontype = "object" }) })
    local code, res = http("POST", M.base() .. "/v1/graphql", body,
        { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. token })
    if type(code) ~= "number" then return nil, "network", 0 end
    if code == 401 then return nil, "auth", code end
    if code == 429 then return nil, "busy", code end
    if code == 403 then return nil, (res and res.error == "insufficient_scope") and "scope" or "refused", code end
    if code >= 400 or not res then return nil, "server", code end
    if res.errors then
        local e = res.errors[1]
        logger.warn("ShelfTechUI: Hardcover:", type(e) == "table" and e.message or tostring(e))
        return nil, "server", code
    end
    return res.data or {}
end

local WHY = {
    network = _("Hardcover didn't answer. Check the Wi-Fi."),
    auth = _("Hardcover no longer accepts this sign-in. Sign in again."),
    busy = _("Hardcover is asking for a pause (too many requests). Try in a minute."),
    scope = _("This key doesn't allow that. Make a new one with the link ShelfTechUI gives."),
    refused = _("Hardcover refused that."),
    server = _("Hardcover had a problem with that."),
    offline = _("Not connected. Turn on Wi-Fi."),
    signedout = _("Not signed in to Hardcover."),
    ["timed out"] = _("Hardcover took too long."),
}
local function say(why) return WHY[why] or WHY.server end

local function Async() return require("bos_store").Async end

-- A link-code sign-in's tokens last a week and are renewed with a second
-- token that works once: renewed here, on the device's own loop, one at a
-- time, and saved before anything else uses them.
local renewing, waiting = false, {}
local function fresh(cb)
    local exp = get("expires")
    if not (get("refresh") and exp and os.time() > exp - 86400) then return cb(true) end
    waiting[#waiting + 1] = cb
    if renewing then return end
    renewing = true
    local refresh, client = get("refresh"), M.clientId() or get("client_used")
    local base = M.base()
    Async().run(function()
        local code, res = http("POST", base .. "/oauth2/token", form{ grant_type = "refresh_token", refresh_token = refresh, client_id = client },
            { ["Content-Type"] = "application/x-www-form-urlencoded" })
        return code, res
    end, function(ok, code, res)
        renewing = false
        local good = ok and type(res) == "table" and res.access_token
        if good then
            set("token", res.access_token)
            if res.refresh_token then set("refresh", res.refresh_token) end
            set("expires", os.time() + (tonumber(res.expires_in) or 604800))
        elseif ok and type(code) == "number" and code >= 400 and code < 500 then
            -- the renewal itself was refused: signed out, to sign in again
            set("token", nil) set("refresh", nil) set("expires", nil)
        end
        local list = waiting
        waiting = {}
        for _i, f in ipairs(list) do pcall(f, M.signedIn()) end
    end, 30)
end

--- Run a query in the background. `shape(data)` (optional, runs in the
--- background too) turns the answer into what the screen wants.
local function call(query, vars, cb, shape)
    cb = cb or function() end
    if not M.signedIn() then return cb(nil, say("signedout")) end
    if not connected() then return cb(nil, say("offline")) end
    fresh(function(still)
        if not still then return cb(nil, say("auth")) end
        local token = get("token")
        Async().run(function()
            local data, why = graphql(token, query, vars)
            if not data then return nil, why end
            if shape then return shape(data, token) end
            return data
        end, function(ok, data, why)
            if not ok then return cb(nil, say(data)) end
            if data == nil then
                -- a key Hardcover no longer takes (expired, or revoked there):
                -- signed out, so the app asks for a new one
                if why == "auth" and not get("refresh") then set("token", nil) end
                return cb(nil, say(why))
            end
            cb(data)
        end, 30)
    end)
end

-- ---------------------------------------------------------------- shapes

local function first(v) return type(v) == "table" and v[1] or nil end

local function imageUrl(img)
    if type(img) == "table" and type(img.url) == "string" and img.url ~= "" then return img.url end
end

local function authorOf(contributors)
    if type(contributors) ~= "table" then return nil end
    local names = {}
    for _i, c in ipairs(contributors) do
        local n = type(c) == "table" and type(c.author) == "table" and c.author.name
        if n and (c.contribution == nil or c.contribution == "" or c.contribution == "Author") then names[#names + 1] = n end
        if #names == 2 then break end
    end
    if #names == 0 then
        local c = contributors[1]
        if type(c) == "table" and type(c.author) == "table" then names[1] = c.author.name end
    end
    return #names > 0 and table.concat(names, ", ") or nil
end

local BOOK = [[
  id title slug pages release_year rating ratings_count users_read_count users_count
  cached_image cached_contributors
]]

local function bookOf(b)
    if type(b) ~= "table" or not b.id then return nil end
    return {
        id = b.id, title = b.title or "", slug = b.slug, pages = b.pages, year = b.release_year,
        rating = tonumber(b.rating), ratings = b.ratings_count or 0, readers = b.users_read_count or 0,
        author = authorOf(b.cached_contributors), image = imageUrl(b.cached_image),
        description = b.description,
    }
end

local function userOf(u)
    if type(u) ~= "table" then return nil end
    return { id = u.id, username = u.username, name = (u.name and u.name ~= "") and u.name or u.username }
end

local function entryOf(ub)
    if type(ub) ~= "table" then return nil end
    local read = first(ub.user_book_reads)
    return { id = ub.id, status = ub.status_id, rating = tonumber(ub.rating), updated = ub.updated_at,
        read_id = read and read.id, pages = read and read.progress_pages,
        edition_pages = read and type(read.edition) == "table" and read.edition.pages or nil }
end

-- ---------------------------------------------------------------- signing in

local ME = "{ me { id username name } }"

local function keep(token, me, extra)
    set("token", token)
    set("user", { id = me.id, username = me.username, name = (me.name and me.name ~= "") and me.name or me.username })
    set("refresh", extra and extra.refresh or nil)
    set("expires", extra and extra.expires or nil)
    set("client_used", extra and extra.client or nil)
end

--- A pasted API key ("Bearer " in front or not): asked of Hardcover who it
--- is, and kept if it answers.
function M.setKey(token, cb)
    cb = cb or function() end
    token = tostring(token or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^[Bb]earer%s+", "")
    if #token < 20 or token:find("%s") then return cb(nil, _("That doesn't look like a Hardcover key.")) end
    if not connected() then return cb(nil, say("offline")) end
    Async().run(function() return graphql(token, ME) end, function(ok, data, why)
        local me = ok and type(data) == "table" and first(data.me)
        if not me then return cb(nil, (ok and why == "auth") and _("Hardcover doesn't know that key. Copy all of it, and check it hasn't expired.") or say(ok and why or data)) end
        keep(token, me)
        cb(M.user())
    end, 30)
end

--- The link code: ask Hardcover for one. cb{ code, uri, qr, expires, every }.
function M.link.start(cb)
    local client = M.clientId()
    if not client then return cb(nil, _("No app ID for Hardcover yet.")) end
    if not connected() then return cb(nil, say("offline")) end
    local base = M.base()
    Async().run(function()
        return http("POST", base .. "/oauth2/device", form{ client_id = client, scope = SCOPES },
            { ["Content-Type"] = "application/x-www-form-urlencoded" })
    end, function(ok, code, res)
        if not (ok and type(res) == "table" and res.device_code and res.user_code) then
            return cb(nil, _("Hardcover didn't give a link code. Check the app ID in Settings."))
        end
        M.link.state = { device = res.device_code, client = client, every = math.max(3, tonumber(res.interval) or 5),
            until_t = os.time() + (tonumber(res.expires_in) or 600) }
        cb({ code = res.user_code, uri = res.verification_uri or "https://hardcover.app/link",
            qr = res.verification_uri_complete or res.verification_uri, every = M.link.state.every,
            expires = M.link.state.until_t })
    end, 30)
end

--- Has the code been approved yet? cb("done", user) | cb("wait") |
--- cb("over", why). Call every `every` seconds.
function M.link.poll(cb)
    local st = M.link.state
    if not st then return cb("over", _("No link code is waiting.")) end
    if os.time() > st.until_t then M.link.state = nil return cb("over", _("The code ran out. Ask for a new one.")) end
    local base = M.base()
    Async().run(function()
        local code, res = http("POST", base .. "/oauth2/token", form{ grant_type = "urn:ietf:params:oauth:grant-type:device_code",
            device_code = st.device, client_id = st.client }, { ["Content-Type"] = "application/x-www-form-urlencoded" })
        if type(res) == "table" and res.access_token then
            local data = graphql(res.access_token, ME)
            return "done", res, data and first(data.me)
        end
        return (type(res) == "table" and res.error) or (type(code) ~= "number" and "network") or "server"
    end, function(ok, what, res, me)
        if M.link.state ~= st then return end
        if not ok then return cb("wait") end
        if what == "done" and me then
            M.link.state = nil
            keep(res.access_token, me, { refresh = res.refresh_token, expires = os.time() + (tonumber(res.expires_in) or 604800), client = st.client })
            return cb("done", M.user())
        end
        if what == "authorization_pending" or what == "network" or what == "server" then return cb("wait") end
        if what == "slow_down" then st.every = st.every + 3 return cb("wait") end
        M.link.state = nil
        cb("over", what == "access_denied" and _("The request was declined on Hardcover.") or _("The code ran out. Ask for a new one."))
    end, 30)
end

function M.link.cancel() M.link.state = nil end

function M.signOut()
    local refresh, client, base = get("refresh"), get("client_used"), M.base()
    if refresh and client and connected() then
        -- (so it no longer shows as a session on Hardcover)
        Async().run(function()
            return http("POST", base .. "/oauth2/revoke", form{ token = refresh, token_type_hint = "refresh_token", client_id = client },
                { ["Content-Type"] = "application/x-www-form-urlencoded" })
        end, function() end, 20)
    end
    for _i, k in ipairs({ "token", "refresh", "expires", "user", "client_used", "queue" }) do set(k, nil) end
    M.cache = {}
end

-- ---------------------------------------------------------------- reading

M.cache = {}
local function cached(key, ttl)
    local c = M.cache[key]
    if c and os.time() - c.at < ttl then return c.data end
end
local function remember(key, data) M.cache[key] = { at = os.time(), data = data } return data end
function M.forget(prefix)
    for k in pairs(M.cache) do if not prefix or k:sub(1, #prefix) == prefix then M.cache[k] = nil end end
end

local function uid() local u = M.user() return u and u.id end

--- Your books of a status, the latest first.
function M.shelf(status, cb)
    local key = "shelf" .. status
    local hit = cached(key, 300)
    if hit then return cb(hit) end
    call([[query ($u: Int!, $s: Int!) {
      user_books(where: {user_id: {_eq: $u}, status_id: {_eq: $s}}, order_by: {updated_at: desc_nulls_last}, limit: 60) {
        id status_id rating updated_at
        user_book_reads(where: {finished_at: {_is_null: true}}, order_by: {id: desc}, limit: 1) { id progress_pages edition { pages } }
        book { ]] .. BOOK .. [[ }
      }
    }]], { u = uid(), s = status }, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember(key, data))
    end, function(data)
        local out = {}
        for _i, ub in ipairs(data.user_books or {}) do
            local b = bookOf(ub.book)
            if b then b.mine = entryOf(ub) out[#out + 1] = b end
        end
        return out
    end)
end

--- What the people you follow are reading and have just read: one line
--- each, the latest first.
function M.friends(cb)
    local hit = cached("friends", 300)
    if hit then return cb(hit) end
    call([[query ($u: Int!) {
      followed_users(where: {user_id: {_eq: $u}}, limit: 60) {
        followed_user {
          id username name
          user_books(where: {status_id: {_in: [2, 3]}}, order_by: {updated_at: desc_nulls_last}, limit: 3) {
            id status_id rating updated_at
            book { ]] .. BOOK .. [[ }
          }
        }
      }
    }]], { u = uid() }, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember("friends", data))
    end, function(data)
        local out = { people = 0 }
        for _i, f in ipairs(data.followed_users or {}) do
            local who = userOf(f.followed_user)
            if who then
                out.people = out.people + 1
                for _k, ub in ipairs(f.followed_user.user_books or {}) do
                    local b = bookOf(ub.book)
                    if b then
                        out[#out + 1] = { who = who, book = b, status = ub.status_id, rating = tonumber(ub.rating), at = ub.updated_at or "" }
                    end
                end
            end
        end
        table.sort(out, function(a, b) return a.at > b.at end)
        return out
    end)
end

local function hydrate(token, ids)
    if #ids == 0 then return {} end
    local data, why = graphql(token, "query ($ids: [Int!]) { books(where: {id: {_in: $ids}}) { " .. BOOK .. " } }", { ids = ids })
    if not data then return nil, why end
    local by = {}
    for _i, b in ipairs(data.books or {}) do by[b.id] = bookOf(b) end
    local out = {}
    for _i, id in ipairs(ids) do if by[id] then out[#out + 1] = by[id] end end
    return out
end

local function idList(ids, max)
    local out = {}
    for _i, id in ipairs(ids or {}) do
        local n = tonumber(id)
        if n then out[#out + 1] = n end
        if #out >= max then break end
    end
    return out
end

--- Popular on Hardcover this month.
function M.trending(cb)
    local hit = cached("trending", 3600)
    if hit then return cb(hit) end
    call("{ books_trending(duration: month, limit: 24) { ids } }", nil, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember("trending", data))
    end, function(data, token)
        return hydrate(token, idList(data.books_trending and data.books_trending.ids, 24))
    end)
end

function M.search(q, cb)
    q = tostring(q or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return cb({}) end
    local key = "search:" .. q:lower()
    local hit = cached(key, 600)
    if hit then return cb(hit) end
    call([[query ($q: String!) { search(query: $q, query_type: "Book", per_page: 20, page: 1) { ids } }]], { q = q }, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember(key, data))
    end, function(data, token)
        return hydrate(token, idList(data.search and data.search.ids, 20))
    end)
end

--- A book: what it is, your entry for it, the quotes readers liked most
--- and their reviews.
function M.book(id, cb)
    local key = "book" .. id
    local hit = cached(key, 300)
    if hit then return cb(hit) end
    call([[query ($id: Int!, $u: Int!) {
      books_by_pk(id: $id) { ]] .. BOOK .. [[ description
        user_books(where: {user_id: {_eq: $u}}, limit: 1) {
          id status_id rating updated_at
          user_book_reads(where: {finished_at: {_is_null: true}}, order_by: {id: desc}, limit: 1) { id progress_pages edition { pages } }
        }
      }
    }]], { id = id, u = uid() }, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember(key, data))
    end, function(data, token)
        local b = bookOf(data.books_by_pk)
        if not b then return nil, "server" end
        b.mine = entryOf(first(data.books_by_pk.user_books))
        b.quotes, b.reviews = {}, {}
        -- (asked for one at a time: a request with several questions in it
        -- can be refused; and the book still shows if these two aren't answered)
        local q = graphql(token, [[query ($id: Int!) {
          reading_journals(where: {book_id: {_eq: $id}, event: {_eq: "quote"}, privacy_setting_id: {_eq: 1}},
              order_by: [{likes_count: desc}, {id: desc}], limit: 12) {
            id entry likes_count user { id username name }
          }
        }]], { id = id })
        for _i, j in ipairs(q and q.reading_journals or {}) do
            local text = type(j.entry) == "string" and j.entry:gsub("^%s+", ""):gsub("%s+$", "") or ""
            if text ~= "" then b.quotes[#b.quotes + 1] = { text = text, likes = j.likes_count or 0, who = userOf(j.user) } end
        end
        local r = graphql(token, [[query ($id: Int!) {
          user_books(where: {book_id: {_eq: $id}, has_review: {_eq: true}, privacy_setting_id: {_eq: 1}},
              order_by: {likes_count: desc}, limit: 8) {
            id rating likes_count review_raw review_has_spoilers user { id username name }
          }
        }]], { id = id })
        for _i, rv in ipairs(r and r.user_books or {}) do
            local text = type(rv.review_raw) == "string" and rv.review_raw:gsub("%s+", " "):gsub("^ ", "") or ""
            if text ~= "" and not rv.review_has_spoilers then
                b.reviews[#b.reviews + 1] = { text = text, rating = tonumber(rv.rating), likes = rv.likes_count or 0, who = userOf(rv.user) }
            end
        end
        return b
    end)
end

--- This year's reading goal: { goal, progress, what } | false.
function M.goal(cb)
    local hit = cached("goal", 1800)
    if hit ~= nil then return cb(hit) end
    call([[query ($u: Int!, $d: date!) {
      goals(where: {user_id: {_eq: $u}, archived: {_eq: false}, start_date: {_lte: $d}, end_date: {_gte: $d}}, order_by: {id: desc}, limit: 1) {
        id goal progress metric description
      }
    }]], { u = uid(), d = os.date("%Y-%m-%d") }, function(data, why)
        if data == nil then return cb(nil, why) end
        cb(remember("goal", data))
    end, function(data)
        local g = first(data.goals)
        if not g then return false end
        return { goal = tonumber(g.goal) or 0, progress = math.floor(tonumber(g.progress) or 0), metric = g.metric, name = g.description }
    end)
end

-- ---------------------------------------------------------------- writing

--- Put a book on a shelf (or move it). cb(entry).
function M.setStatus(book_id, status, cb)
    call([[mutation ($o: UserBookCreateInput!) {
      insert_user_book(object: $o) { error user_book { id status_id rating updated_at } }
    }]], { o = { book_id = book_id, status_id = status } }, function(data, why)
        if not data then return (cb or function() end)(nil, why) end
        M.forget("shelf") M.forget("book" .. book_id)
        if cb then cb(data) end
    end, function(data)
        local r = data.insert_user_book
        if not r or r.error or not r.user_book then return nil, "refused" end
        return entryOf(r.user_book)
    end)
end

--- Your rating (0.5 to 5; 0 takes it away). cb(entry).
function M.rate(user_book_id, rating, book_id, cb)
    local rapidjson = require("rapidjson")
    call([[mutation ($id: Int!, $o: UserBookUpdateInput!) {
      update_user_book(id: $id, object: $o) { error user_book { id status_id rating updated_at } }
    }]], { id = user_book_id, o = { rating = (rating and rating > 0) and rating or rapidjson.null } }, function(data, why)
        if not data then return (cb or function() end)(nil, why) end
        M.forget("shelf") if book_id then M.forget("book" .. book_id) end
        if cb then cb(data) end
    end, function(data)
        local r = data.update_user_book
        if not r or r.error or not r.user_book then return nil, "refused" end
        return entryOf(r.user_book)
    end)
end

--- A passage, kept on Hardcover as a quote from the book.
function M.quote(book_id, text, cb)
    local privacy = get("quote_privacy", 1)
    call([[mutation ($o: ReadingJournalCreateType!) {
      insert_reading_journal(object: $o) { errors id }
    }]], { o = { book_id = book_id, event = "quote", entry = text, privacy_setting_id = privacy,
        tags = setmetatable({}, { __jsontype = "array" }) } }, function(data, why)
        if not data then return (cb or function() end)(nil, why) end
        M.forget("book" .. book_id)
        if cb then cb(true) end
    end, function(data)
        local r = data.insert_reading_journal
        if not r or (type(r.errors) == "table" and #r.errors > 0) then return nil, "refused" end
        return true
    end)
end

-- ---------------------------------------------------------------- your files

local function norm(s)
    s = tostring(s or ""):lower():gsub("%b()", " "):gsub("[%p]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return s
end
M.norm = norm

--- The Hardcover book a file is: { id, title, author, pages, entry, read_id,
--- status } | nil.
function M.linkFor(file)
    local links = get("links", {})
    return file and links[file] or nil
end

function M.setLink(file, link)
    local links = get("links", {})
    links[file] = link
    set("links", links)
end

--- The likeliest Hardcover book for a title and an author: cb(book, sure).
--- `sure` when the title is the same and the author agrees: linked without
--- asking.
function M.match(title, author, cb)
    local short = tostring(title or ""):gsub(":.+", "")
    if norm(short) == "" then return cb(nil) end
    M.search(short .. " " .. (author or ""), function(list, why)
        if not list then return cb(nil, false, why) end
        local a = norm(author)
        local a_last = a:match("(%S+)$") or ""
        for _i, b in ipairs(list) do
            local same_title = norm(b.title) == norm(title) or norm(b.title) == norm(short)
            local same_author = a == "" or (b.author and norm(b.author):find(a_last, 1, true) ~= nil)
            if same_title and same_author then return cb(b, true) end
        end
        cb(list[1], false)
    end)
end

-- What couldn't be sent (no Wi-Fi just then) waits here, and goes when the
-- device is next connected. One entry per book and kind: the latest wins.
local function queue(kind, file, value)
    local q = get("queue", {})
    q[kind .. "|" .. file] = { kind = kind, file = file, value = value, at = os.time() }
    set("queue", q)
end

local sending = false
--- Send what's waiting (called when Wi-Fi comes on, and after a book).
function M.flush()
    if sending or not (M.signedIn() and connected()) then return end
    local q = get("queue", {})
    local key, job = next(q)
    if not key then return end
    sending = true
    local function done(ok)
        sending = false
        local now = get("queue", {})
        -- (kept for another try only if nothing newer took its place)
        if ok or (now[key] and now[key].at == job.at and os.time() - job.at > 14 * 86400) then
            if now[key] and now[key].at == job.at then now[key] = nil set("queue", now) end
        end
        if ok then UIManager:scheduleIn(1, M.flush) end
    end
    local link = M.linkFor(job.file)
    if not link then return done(true) end
    if job.kind == "status" then
        M.setStatus(link.id, job.value, function(entry)
            if entry then
                link.entry, link.status = entry.id, entry.status
                link.read_id = nil
                M.setLink(job.file, link)
            end
            done(entry ~= nil)
        end)
    elseif job.kind == "progress" then
        M.sendProgress(job.file, job.value, function(ok) done(ok) end)
    else
        done(true)
    end
end

--- The status of a linked book, now or when next connected.
function M.status(file, status)
    local link = M.linkFor(file)
    if not link or link.status == status then return end
    queue("status", file, status)
    M.flush()
end

--- Where you are in a linked book (0..1), now or when next connected.
function M.progress(file, percent)
    local link = M.linkFor(file)
    if not link or not percent then return end
    if link.sent and math.abs(link.sent - percent) < 0.01 then return end
    queue("progress", file, percent)
    M.flush()
end

function M.sendProgress(file, percent, cb)
    local link = M.linkFor(file)
    if not link then return cb(true) end
    -- the read in progress and its edition's length are asked for first
    -- (the pages on Hardcover are that edition's, not this file's)
    call([[query ($u: Int!, $b: Int!) {
      user_books(where: {user_id: {_eq: $u}, book_id: {_eq: $b}}, limit: 1) {
        id status_id
        user_book_reads(where: {finished_at: {_is_null: true}}, order_by: {id: desc}, limit: 1) { id progress_pages edition { pages } }
        book { pages }
      }
    }]], { u = uid(), b = link.id }, function(entry, why)
        if entry == nil then return cb(false) end
        if entry == false then return cb(true) end -- (not on a shelf, or not being read: nothing to say)
        link.entry, link.status, link.read_id, link.sent = entry.id, entry.status, entry.read_id, percent
        M.setLink(file, link)
        M.forget("shelf")
        cb(true)
    end, function(data, token)
        local ub = first(data.user_books)
        if not ub or ub.status_id ~= 2 then return false end
        local read = first(ub.user_book_reads)
        local pages = (read and type(read.edition) == "table" and read.edition.pages) or (type(ub.book) == "table" and ub.book.pages) or link.pages
        if not pages or pages <= 0 then return false end
        -- (never the last page: reaching it marks the book read, which is
        -- said on purpose, at the book's end)
        local page = math.max(1, math.min(pages - 1, math.floor(percent * pages + 0.5)))
        local res, why
        if read then
            if read.progress_pages == page then return { id = ub.id, status = 2, read_id = read.id } end
            res, why = graphql(token, [[mutation ($id: Int!, $p: Int!) {
              update_user_book_read(id: $id, object: {progress_pages: $p}) { error user_book_read { id } }
            }]], { id = read.id, p = page })
            if not res or (res.update_user_book_read and res.update_user_book_read.error) then return nil, why or "refused" end
            return { id = ub.id, status = 2, read_id = read.id }
        end
        res, why = graphql(token, [[mutation ($id: Int!, $p: Int!, $d: date) {
          insert_user_book_read(user_book_id: $id, user_book_read: {progress_pages: $p, started_at: $d}) { error user_book_read { id } }
        }]], { id = ub.id, p = page, d = os.date("%Y-%m-%d") })
        local r = res and res.insert_user_book_read
        if not r or r.error then return nil, why or "refused" end
        return { id = ub.id, status = 2, read_id = r.user_book_read and r.user_book_read.id }
    end)
end

-- ---------------------------------------------------------------- covers

local function coverDir()
    local dir = DataStorage:getDataDir() .. "/cache/stui_hardcover"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(dir)
    end
    return dir
end

--- A book's cover on the device, if it's been fetched (never fetches).
function M.coverPath(book)
    if not (book and book.id and book.image) then return nil end
    local path = coverDir() .. "/" .. book.id .. ".jpg"
    if require("libs/libkoreader-lfs").attributes(path, "mode") == "file" then return path end
end

--- Fetch the covers of these books that aren't here yet (a few at a time,
--- in the background); done() when something new arrived.
local asked = {}
function M.fetchCovers(books, done, max)
    if not connected() then return end
    local want = {}
    for _i, b in ipairs(books) do
        if b and b.id and b.image and not asked[b.id] and not M.coverPath(b) then
            asked[b.id] = true
            want[#want + 1] = { url = b.image, path = coverDir() .. "/" .. b.id .. ".jpg" }
            if #want >= (max or 12) then break end
        end
    end
    if #want == 0 then return end
    for i = 1, #want, 4 do
        local batch = { want[i], want[i + 1], want[i + 2], want[i + 3] }
        Async().run(function()
            local got = 0
            for _k, w in ipairs(batch) do
                local ok, res = pcall(function()
                    return require("lib/bookshelf_cover_fetch").download(w.url, w.path, nil, nil, { block_timeout = 8, total_timeout = 15 })
                end)
                if ok and res then got = got + 1 end
            end
            return got
        end, function(ok, got) if ok and (got or 0) > 0 and done then done() end end, 70)
    end
end

--- Old covers go (kept a month).
function M.prune()
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local dir = coverDir()
        local cutoff = os.time() - 30 * 86400
        for name in lfs.dir(dir) do
            local p = dir .. "/" .. name
            local a = lfs.attributes(p)
            if a and a.mode == "file" and (a.access or a.modification or 0) < cutoff then os.remove(p) end
        end
    end)
end

return M
