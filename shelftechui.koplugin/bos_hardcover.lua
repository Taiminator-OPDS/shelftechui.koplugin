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
  M.social(cb, force)       the readers you follow, each with what they're
                            reading and how far (kept on the device:
                            M.socialCached() never asks the network)
  M.friendsWith(title, id)  who among them has a book
  M.profile(user_id, cb)    a reader's page
  M.stats(user_id, cb)      a reader's figures (yours with no id)
  M.sendHistory(list, cb)   this device's reading history, sent in one go
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
local SCOPES = "read:me:content read:catalog read:library read:journal read:social read:users read:goals write:library write:social"
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
    M.mineClear()
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

--- How far along a read is: percent (0..100) and the page, or nil.
local function progressOf(read, book_pages)
    if type(read) ~= "table" then return nil end
    local pages = (type(read.edition) == "table" and tonumber(read.edition.pages)) or tonumber(book_pages)
    local page = tonumber(read.progress_pages)
    if page and pages and pages > 0 then
        return math.max(0, math.min(100, math.floor(100 * page / pages + 0.5))), page
    end
    local p = tonumber(read.progress)
    if p and p > 0 then return math.max(0, math.min(100, math.floor(p + 0.5))), page end
    return nil, page
end

local READS = "user_book_reads(order_by: {id: desc}, limit: 1) { progress progress_pages started_at finished_at edition { pages } }"

local function shelfRow(ub)
    local b = bookOf(ub.book)
    if not b then return nil end
    local pct, page = progressOf(first(ub.user_book_reads), b.pages)
    return { book = b, status = ub.status_id, rating = tonumber(ub.rating), at = ub.updated_at or ub.last_read_date or "",
        percent = ub.status_id == 2 and pct or nil, page = ub.status_id == 2 and page or nil }
end

-- What's known about the readers you follow is kept on the device (its own
-- file), so home's badges and the start menu's list never wait on the
-- network: they show what was last fetched, and it's fetched again in the
-- background when it's older than a quarter of an hour and Wi-Fi is on.
local social_file, social_mem
local function socialStore()
    if not social_file then social_file = LuaSettings:open(DataStorage:getSettingsDir() .. "/stui_hardcover_social.lua") end
    return social_file
end

--- The readers you follow, as last fetched (never asks the network):
--- { at, people = { { id, username, name, books, followers, reading = {
--- { book, percent, page, at } }, finished = { { book, rating, at } } } } }.
function M.socialCached()
    if not social_mem then
        local v = socialStore():readSetting("social")
        social_mem = type(v) == "table" and v or { at = 0, people = {} }
    end
    return social_mem
end

local social_waiting
--- The readers you follow, fresh when it can be: cb(social) at once from
--- what's kept when that's recent (or there's no Wi-Fi), else after asking.
function M.social(cb, force)
    local kept = M.socialCached()
    if not M.signedIn() then return cb({ at = 0, people = {} }) end
    if not force and (os.time() - (kept.at or 0) < 900 or not connected()) then return cb(kept) end
    if not connected() then return cb(kept, say("offline")) end
    if social_waiting then social_waiting[#social_waiting + 1] = cb return end
    social_waiting = { cb }
    call([[query ($u: Int!) {
      followed_users(where: {user_id: {_eq: $u}}, limit: 80) {
        followed_user {
          id username name books_count followers_count
          user_books(where: {status_id: {_in: [2, 3]}}, order_by: {updated_at: desc_nulls_last}, limit: 5) {
            id status_id rating updated_at
            ]] .. READS .. [[
            book { ]] .. BOOK .. [[ }
          }
        }
      }
    }]], { u = uid() }, function(data, why)
        local list = social_waiting or {}
        social_waiting = nil
        if data then
            social_mem = data
            socialStore():saveSetting("social", data)
            socialStore():flush()
            M.social_gen = (M.social_gen or 0) + 1
        end
        for _i, f in ipairs(list) do pcall(f, data or kept, why) end
    end, function(data)
        local out = { at = os.time(), people = {} }
        for _i, f in ipairs(data.followed_users or {}) do
            local who = userOf(f.followed_user)
            if who then
                who.books, who.followers = f.followed_user.books_count, f.followed_user.followers_count
                who.reading, who.finished = {}, {}
                for _k, ub in ipairs(f.followed_user.user_books or {}) do
                    local row = shelfRow(ub)
                    if row then
                        if row.status == 2 then who.reading[#who.reading + 1] = row else who.finished[#who.finished + 1] = row end
                    end
                end
                who.at = (who.reading[1] and who.reading[1].at) or (who.finished[1] and who.finished[1].at) or ""
                out.people[#out.people + 1] = who
            end
        end
        -- those reading now first, the latest first
        table.sort(out.people, function(a, b)
            local ra, rb = #a.reading > 0, #b.reading > 0
            if ra ~= rb then return ra end
            return (a.at or "") > (b.at or "")
        end)
        return out
    end)
end

--- Refresh what's kept, quietly, when it's old and Wi-Fi is on (home and
--- the start menu call this; it costs nothing when there's nothing to do).
function M.socialTouch(done)
    if not M.signedIn() or not connected() then return end
    if os.time() - (M.socialCached().at or 0) < 900 or social_waiting then return end
    M.social(function() if done then pcall(done) end end)
end

-- Your own Reading and Want to read shelves, kept on the device the same way
-- (home's library shows the ones that aren't on this device: never waits on
-- the network for them).
local mine_mem
--- { at, books = { { book fields…, status = 1|2 } } } as last fetched.
function M.mineCached()
    if not mine_mem then
        local v = socialStore():readSetting("mine")
        mine_mem = type(v) == "table" and v or { at = 0, books = {} }
    end
    return mine_mem
end

--- (signed out: another account's shelves aren't kept)
function M.mineClear()
    mine_mem = { at = 0, books = {} }
    socialStore():saveSetting("mine", mine_mem)
    socialStore():flush()
    M.mine_gen = (M.mine_gen or 0) + 1
end

local mine_waiting
--- Fetch your Reading and Want to read shelves again; cb(mine) when done.
function M.mine(cb, force)
    cb = cb or function() end
    local kept = M.mineCached()
    if not M.signedIn() then return cb({ at = 0, books = {} }) end
    if not force and os.time() - (kept.at or 0) < 900 then return cb(kept) end
    if not connected() then return cb(kept, say("offline")) end
    if mine_waiting then mine_waiting[#mine_waiting + 1] = cb return end
    mine_waiting = { cb }
    call([[query ($u: Int!) {
      user_books(where: {user_id: {_eq: $u}, status_id: {_in: [1, 2]}}, order_by: {updated_at: desc_nulls_last}, limit: 120) {
        id status_id updated_at
        book { ]] .. BOOK .. [[ }
      }
    }]], { u = uid() }, function(data, why)
        local list = mine_waiting or {}
        mine_waiting = nil
        if data then
            mine_mem = data
            socialStore():saveSetting("mine", data)
            socialStore():flush()
            M.mine_gen = (M.mine_gen or 0) + 1
        end
        for _i, f in ipairs(list) do pcall(f, data or kept, why) end
    end, function(data)
        local out = { at = os.time(), books = {} }
        for _i, ub in ipairs(data.user_books or {}) do
            local b = bookOf(ub.book)
            if b then
                b.description = nil -- (not needed here: keeps the file small)
                b.status, b.entry = ub.status_id, ub.id
                out.books[#out.books + 1] = b
            end
        end
        return out
    end)
end

--- Fetch it again in the background when it's old and Wi-Fi is on.
function M.mineTouch(done)
    if not M.signedIn() or not connected() or mine_waiting then return end
    if os.time() - (M.mineCached().at or 0) < 900 then return end
    M.mine(function() if done then pcall(done) end end)
end

--- A book left your shelves (or moved): forget it at once, fetch again soon.
local function mineChanged(book_id, status)
    local m = M.mineCached()
    for i = #m.books, 1, -1 do
        local b = m.books[i]
        if b.id == book_id then
            if status == 1 or status == 2 then b.status = status else table.remove(m.books, i) end
        end
    end
    m.at = 0
    M.mine_gen = (M.mine_gen or 0) + 1
end

-- A title, as it's compared (the same book in two catalogues).
local function tkey(s)
    s = tostring(s or ""):lower():gsub("%b()", " "):gsub(":.*$", ""):gsub("^the ", ""):gsub("^an? ", ""):gsub("[^%w]", "")
    return s
end

local by_title = { gen = -1, map = {} }
--- Who among the readers you follow has this book, by title (and by its
--- Hardcover id when the file is linked): { { who, percent, page, status,
--- rating } } or nil. From what's kept: instant, and safe while painting.
function M.friendsWith(title, hc_id)
    if not M.signedIn() then return nil end
    local soc = M.socialCached()
    if by_title.gen ~= (M.social_gen or 0) or by_title.at ~= soc.at then
        local map, ids = {}, {}
        local function add(who, row, status)
            local e = { who = who, percent = row.percent, page = row.page, status = status, rating = row.rating }
            local k = tkey(row.book.title)
            if k ~= "" then map[k] = map[k] or {} table.insert(map[k], e) end
            ids[row.book.id] = ids[row.book.id] or {}
            table.insert(ids[row.book.id], e)
        end
        for _i, who in ipairs(soc.people or {}) do
            for _k, row in ipairs(who.reading or {}) do add(who, row, 2) end
            for _k, row in ipairs(who.finished or {}) do add(who, row, 3) end
        end
        by_title = { gen = M.social_gen or 0, at = soc.at, map = map, ids = ids }
    end
    if hc_id and by_title.ids[hc_id] then return by_title.ids[hc_id] end
    local k = tkey(title)
    return k ~= "" and by_title.map[k] or nil
end

--- A reader's page: who they are, what they're reading (and how far), what
--- they've finished lately, and their counts.
function M.profile(user_id, cb)
    local key = "profile" .. user_id
    local hit = cached(key, 300)
    if hit then return cb(hit) end
    call([[query ($id: Int!) {
      users(where: {id: {_eq: $id}}, limit: 1) {
        id username name bio books_count followers_count followed_users_count
        reading: user_books(where: {status_id: {_eq: 2}}, order_by: {updated_at: desc_nulls_last}, limit: 6) {
          id status_id rating updated_at
          ]] .. READS .. [[
          book { ]] .. BOOK .. [[ }
        }
        finished: user_books(where: {status_id: {_eq: 3}}, order_by: [{last_read_date: desc_nulls_last}, {updated_at: desc_nulls_last}], limit: 12) {
          id status_id rating updated_at last_read_date
          book { ]] .. BOOK .. [[ }
        }
        want: user_books_aggregate(where: {status_id: {_eq: 1}}) { aggregate { count } }
      }
    }]], { id = user_id }, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember(key, data))
    end, function(data)
        local u = first(data.users)
        local who = userOf(u)
        if not who then return nil, "refused" end
        who.bio = type(u.bio) == "string" and u.bio ~= "" and u.bio or nil
        who.books, who.followers, who.follows = u.books_count, u.followers_count, u.followed_users_count
        who.want = type(u.want) == "table" and type(u.want.aggregate) == "table" and u.want.aggregate.count or nil
        who.reading, who.finished = {}, {}
        for _i, ub in ipairs(u.reading or {}) do local r = shelfRow(ub) if r then who.reading[#who.reading + 1] = r end end
        for _i, ub in ipairs(u.finished or {}) do local r = shelfRow(ub) if r then who.finished[#who.finished + 1] = r end end
        return who
    end)
end

--- A reader's figures from their Read shelf (yours with no id): books and
--- pages in all and this year, the average of their ratings, how many a
--- year and a month, the authors they've read most, and their goal.
function M.stats(user_id, cb)
    user_id = user_id or uid()
    local key = "stats" .. tostring(user_id)
    local hit = cached(key, 1800)
    if hit then return cb(hit) end
    call([[query ($id: Int!) {
      user_books(where: {user_id: {_eq: $id}, status_id: {_eq: 3}}, order_by: {last_read_date: desc_nulls_last}, limit: 600) {
        rating last_read_date date_added
        book { pages cached_contributors }
      }
    }]], { id = user_id }, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember(key, data))
    end, function(data, token)
        local year = os.date("%Y")
        local st = { books = 0, pages = 0, year_books = 0, year_pages = 0, rated = 0, rating_sum = 0,
            years = {}, months = {}, authors = {}, dist = { 0, 0, 0, 0, 0 } }
        for m = 1, 12 do st.months[m] = 0 end
        local authors = {}
        for _i, ub in ipairs(data.user_books or {}) do
            st.books = st.books + 1
            local pages = type(ub.book) == "table" and tonumber(ub.book.pages) or 0
            st.pages = st.pages + pages
            local day = type(ub.last_read_date) == "string" and ub.last_read_date or (type(ub.date_added) == "string" and ub.date_added) or ""
            local y, m = day:match("^(%d%d%d%d)%-(%d%d)")
            if y then
                st.years[y] = (st.years[y] or 0) + 1
                if y == year then
                    st.year_books = st.year_books + 1
                    st.year_pages = st.year_pages + pages
                    st.months[tonumber(m)] = st.months[tonumber(m)] + 1
                end
            end
            local r = tonumber(ub.rating)
            if r and r > 0 then
                st.rated = st.rated + 1
                st.rating_sum = st.rating_sum + r
                local bucket = math.max(1, math.min(5, math.floor(r + 0.5)))
                st.dist[bucket] = st.dist[bucket] + 1
            end
            local a = type(ub.book) == "table" and authorOf(ub.book.cached_contributors)
            if a then
                a = a:match("^[^,]+") or a
                authors[a] = (authors[a] or 0) + 1
            end
        end
        st.average = st.rated > 0 and (st.rating_sum / st.rated) or nil
        for name, n in pairs(authors) do st.authors[#st.authors + 1] = { name = name, n = n } end
        table.sort(st.authors, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
        for i = #st.authors, 6, -1 do st.authors[i] = nil end
        st.capped = #(data.user_books or {}) >= 600
        -- their goal for the year, if they show one
        local g = graphql(token, [[query ($u: Int!, $d: date!) {
          goals(where: {user_id: {_eq: $u}, archived: {_eq: false}, start_date: {_lte: $d}, end_date: {_gte: $d}}, order_by: {id: desc}, limit: 1) {
            goal progress metric
          }
        }]], { u = user_id, d = os.date("%Y-%m-%d") })
        local goal = g and first(g.goals)
        if goal then st.goal = { goal = tonumber(goal.goal) or 0, progress = math.floor(tonumber(goal.progress) or 0) } end
        return st
    end)
end

local function hydrate(token, ids, with_description)
    if #ids == 0 then return {} end
    local data, why = graphql(token, "query ($ids: [Int!]) { books(where: {id: {_in: $ids}}) { " .. BOOK
        .. (with_description and " description" or "") .. " } }", { ids = ids })
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

-- ---------------------------------------------------------------- genres and moods

-- What Hardcover's readers tag books with, by kind (a book's cached_tags:
-- { Genre = { { tag = "Fantasy", count = … }, … }, Mood = { … }, … }).
-- The names have to be Hardcover's own, letter for letter, to find books
-- by them: these are a start, and the tags of your own books and this
-- month's popular ones are added (and put first) when they come.
M.KINDS = { genre = "Genre", mood = "Mood" }
local STARTER = {
    genre = { "Fiction", "Fantasy", "Science fiction", "Romance", "Mystery", "Thriller", "Horror", "Historical fiction",
        "Classics", "Literary fiction", "Young Adult", "Nonfiction", "History", "Biography", "Memoir", "Philosophy",
        "Poetry", "Humor", "Adventure", "Dystopian" },
    mood = { "adventurous", "challenging", "dark", "emotional", "funny", "hopeful", "informative", "inspiring",
        "lighthearted", "mysterious", "reflective", "relaxing", "sad", "tense" },
}

--- The tags of a book's cached_tags, of a kind ("Genre", "Mood"), in order.
local function tagsOf(cached, kind)
    local out = {}
    if type(cached) == "string" then
        local ok, t = pcall(require("rapidjson").decode, cached)
        cached = ok and t or nil
    end
    local list = type(cached) == "table" and cached[kind]
    local seen = {}
    for _i, t in ipairs(type(list) == "table" and list or {}) do
        local name = type(t) == "table" and t.tag or (type(t) == "string" and t)
        if type(name) == "string" and name ~= "" and not seen[name:lower()] then
            seen[name:lower()] = true
            out[#out + 1] = name
        end
    end
    return out
end
M.tagsOf = tagsOf

--- Genres and moods to browse by: { genre = { names… }, mood = { names… } },
--- the most used among your books and this month's popular ones first.
function M.tags(cb)
    local hit = cached("tags", 86400)
    if hit then return cb(hit) end
    local function starter()
        local out = {}
        for k, list in pairs(STARTER) do out[k] = { unpack(list) } end
        return out
    end
    call([[query ($u: Int!) {
      user_books(where: {user_id: {_eq: $u}}, order_by: {updated_at: desc_nulls_last}, limit: 120) { book { cached_tags } }
    }]], { u = uid() }, function(data)
        -- (no answer: the starter lists, not kept, so asked again next time)
        if not data then return cb(starter()) end
        cb(remember("tags", data))
    end, function(data, token)
        local seen = { genre = {}, mood = {} }
        local function add(cached_tags, w)
            for key, kind in pairs(M.KINDS) do
                for i, name in ipairs(tagsOf(cached_tags, kind)) do
                    -- (a book's first tags are the ones most readers gave it)
                    if i <= 5 then seen[key][name] = (seen[key][name] or 0) + w * (6 - i) end
                end
            end
        end
        for _i, ub in ipairs(data.user_books or {}) do add(ub.book and ub.book.cached_tags, 2) end
        -- (asked separately: a request with several questions in it can be refused)
        local tr = graphql(token, "{ books_trending(duration: month, limit: 60) { ids } }")
        local ids = idList(tr and tr.books_trending and tr.books_trending.ids, 60)
        if #ids > 0 then
            local more = graphql(token, "query ($ids: [Int!]) { books(where: {id: {_in: $ids}}) { cached_tags } }", { ids = ids })
            for _i, b in ipairs(more and more.books or {}) do add(b.cached_tags, 1) end
        end
        local out = {}
        for key, counts in pairs(seen) do
            local list = {}
            for name, n in pairs(counts) do list[#list + 1] = { name, n } end
            table.sort(list, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
            local names, have = {}, {}
            for _i, e in ipairs(list) do
                if #names >= 24 then break end
                names[#names + 1] = e[1] have[e[1]:lower()] = true
            end
            -- (then the starter's, so there's always something to pick)
            for _i, name in ipairs(STARTER[key]) do
                if #names >= 24 then break end
                if not have[name:lower()] then names[#names + 1] = name have[name:lower()] = true end
            end
            out[key] = names
        end
        return out
    end)
end

--- Books with a genre or a mood (`key`: "genre" | "mood"), the most read first.
function M.byTag(key, name, cb)
    local kind = M.KINDS[key]
    if not (kind and name and name ~= "") then return cb({}) end
    local ck = "tag:" .. key .. ":" .. name:lower()
    local hit = cached(ck, 3600)
    if hit then return cb(hit) end
    call([[query ($t: jsonb!) {
      books(where: {cached_tags: {_contains: $t}}, order_by: {users_read_count: desc_nulls_last}, limit: 48) { ]] .. BOOK .. [[ }
    }]], { t = { [kind] = { { tag = name } } } }, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember(ck, data))
    end, function(data)
        local out = {}
        for _i, b in ipairs(data.books or {}) do out[#out + 1] = bookOf(b) end
        return out
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
      books_by_pk(id: $id) { ]] .. BOOK .. [[ description cached_tags
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
        b.genres = tagsOf(data.books_by_pk.cached_tags, "Genre")
        b.moods = tagsOf(data.books_by_pk.cached_tags, "Mood")
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
--- A book's details, to put on a file: cb({ id, title, subtitle, authors =
--- {…}, description, series, series_index, genres = {…}, year, pages, image }
--- | nil, why). Series where Hardcover has one (asked apart: the book's
--- details come even if that part is refused).
--- The editions of book `id` (most read first): cb(list) with
--- { id, title, subtitle, format, pages, year, isbn, language, publisher,
--- image } each, or cb(nil, why).
function M.editions(id, cb)
    call("query { me { id } }", nil, cb, function(_data, token)
        local q = [[query ($id: Int!) {
          editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc_nulls_last}, limit: 40) {
            id title subtitle pages release_date edition_format isbn_13 isbn_10 cached_image%s
          }
        }]]
        -- (language and publisher are their own tables: asked for, and left
        -- out if Hardcover won't have them)
        local d = graphql(token, q:format(" language { language } publisher { name }"), { id = id })
            or graphql(token, q:format(""), { id = id })
        if not (d and type(d.editions) == "table") then return nil, "server" end
        local out = {}
        for _i, e in ipairs(d.editions) do
            if type(e) == "table" and e.id then
                out[#out + 1] = { id = e.id, title = e.title, subtitle = e.subtitle,
                    format = e.edition_format, pages = tonumber(e.pages),
                    year = type(e.release_date) == "string" and tonumber(e.release_date:match("^(%d%d%d%d)")) or nil,
                    isbn = e.isbn_13 or e.isbn_10,
                    language = type(e.language) == "table" and e.language.language or nil,
                    publisher = type(e.publisher) == "table" and e.publisher.name or nil,
                    image = imageUrl(e.cached_image) }
            end
        end
        return out
    end)
end

--- A book's details: title, authors, description, genres, series, cover…
--- With `edition` (one of M.editions'), that edition's title, length,
--- year, cover, language and publisher in place of the book's.
function M.details(id, cb, edition)
    call("query { me { id } }", nil, cb, function(_data, token)
        local d = graphql(token, [[query ($id: Int!) {
          books_by_pk(id: $id) { id title subtitle description release_year pages cached_image cached_contributors cached_tags }
        }]], { id = id })
        local b = d and d.books_by_pk
        if type(b) ~= "table" then return nil, "server" end
        local out = { id = b.id, title = b.title, subtitle = b.subtitle, description = b.description,
            year = b.release_year, pages = b.pages, image = imageUrl(b.cached_image), authors = {} }
        for _i, c in ipairs(type(b.cached_contributors) == "table" and b.cached_contributors or {}) do
            local n = type(c) == "table" and type(c.author) == "table" and c.author.name
            if n and (c.contribution == nil or c.contribution == "" or c.contribution == "Author") then
                out.authors[#out.authors + 1] = n
            end
        end
        if #out.authors == 0 then
            local a = authorOf(b.cached_contributors)
            if a then out.authors = { a } end
        end
        out.genres = tagsOf(b.cached_tags, "Genre")
        local sr = graphql(token, [[query ($id: Int!) {
          book_series(where: {book_id: {_eq: $id}}, order_by: {position: asc_nulls_last}, limit: 1) { position series { name } }
        }]], { id = id })
        local s1 = sr and first(sr.book_series)
        if s1 and type(s1.series) == "table" and s1.series.name then
            out.series = s1.series.name
            out.series_index = tonumber(s1.position)
        end
        if type(edition) == "table" then
            if edition.title and edition.title ~= "" then out.title, out.subtitle = edition.title, edition.subtitle end
            out.pages = edition.pages or out.pages
            out.year = edition.year or out.year
            out.image = edition.image or out.image
            out.language, out.publisher, out.isbn = edition.language, edition.publisher, edition.isbn
            out.edition = edition.id
        end
        return out
    end)
end

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

--- Recommendations from Hardcover, here and now (so: only in a background
--- process; bos_online's daily fetch calls it). Books like the ones you
--- rated highest and are reading, then what the readers you follow are
--- reading, then this month's popular ones; never a book on your shelves
--- or on the device (`have`: titles, normalised by `norm`). Returns picks
--- in bos_online's shape.
function M.recommendNow(have, norm_title)
    if not (M.signedIn() and connected()) then return {} end
    local token, u = get("token"), uid()
    if not u then return {} end
    have = have or {}
    norm_title = norm_title or function(t) return tostring(t or ""):lower() end
    local mine = {}
    local all = graphql(token, "query ($u: Int!) { user_books(where: {user_id: {_eq: $u}}, limit: 1000) { book_id } }", { u = u })
    for _i, ub in ipairs(all and all.user_books or {}) do mine[ub.book_id] = true end
    local ids, seen, why = {}, {}, {}
    local function add(id, because)
        id = tonumber(id)
        if id and not mine[id] and not seen[id] and #ids < 36 then seen[id] = true ids[#ids + 1] = id why[id] = because end
    end
    -- like the books you rated 4 or more: a book high in several of their
    -- "similar" lists scores best, one you rated 4.5+ counting double (the
    -- scoring Hardcover Sync uses); the reason is the book that counted most
    local seeds = graphql(token, [[query ($u: Int!) {
      user_books(where: {user_id: {_eq: $u}, _or: [{rating: {_gte: 4}}, {status_id: {_eq: 2}}]},
          order_by: [{updated_at: desc_nulls_last}], limit: 15) {
        rating status_id
        book { id title cached_similar_book_ids }
      }
    }]], { u = u })
    local score, best = {}, {}
    local DEPTH = 30
    for _i, ub in ipairs(seeds and seeds.user_books or {}) do
        local book = type(ub.book) == "table" and ub.book
        local sim = book and book.cached_similar_book_ids
        if type(sim) == "table" then
            local rating = tonumber(ub.rating) or 4
            local weight = rating >= 4.5 and 2 or 1
            local rank = 0
            for _k, v in ipairs(sim) do
                local id = tonumber(type(v) == "table" and (v.id or v.book_id) or v)
                if id then
                    rank = rank + 1
                    if rank > DEPTH then break end
                    local gain = weight * (DEPTH + 1 - rank)
                    score[id] = (score[id] or 0) + gain
                    if not best[id] or gain > best[id].gain then best[id] = { gain = gain, title = book.title } end
                end
            end
        end
    end
    local ranked = {}
    for id, sc in pairs(score) do ranked[#ranked + 1] = { id = id, score = sc } end
    table.sort(ranked, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.id < b.id end)
    for _i, r in ipairs(ranked) do add(r.id, best[r.id] and best[r.id].title or "similar") end
    -- what the readers you follow are reading
    if #ids < 24 then
        local fr = graphql(token, [[query ($u: Int!) {
          followed_users(where: {user_id: {_eq: $u}}, limit: 40) {
            followed_user { user_books(where: {status_id: {_in: [2, 3]}}, order_by: {updated_at: desc_nulls_last}, limit: 3) { book_id } }
          }
        }]], { u = u })
        for _i, f in ipairs(fr and fr.followed_users or {}) do
            for _k, ub in ipairs(type(f.followed_user) == "table" and f.followed_user.user_books or {}) do add(ub.book_id, "friends") end
        end
    end
    -- and what's popular
    if #ids < 24 then
        local tr = graphql(token, "{ books_trending(duration: month, limit: 30) { ids } }")
        for _i, id in ipairs(tr and tr.books_trending and tr.books_trending.ids or {}) do add(id, "popular") end
    end
    local books = hydrate(token, ids, true) or {}
    local out = {}
    for _i, b in ipairs(books) do
        if b.title ~= "" and not have[norm_title(b.title)] then
            local desc = type(b.description) == "string" and b.description:gsub("<[^>]+>", ""):gsub("%s+", " ") or nil
            if desc and #desc > 900 then desc = desc:sub(1, 900):gsub("[\128-\191]*$", "") .. "…" end
            local because = why[b.id]
            out[#out + 1] = { online = true, key = "hc:" .. b.id, title = b.title, author = b.author, year = b.year,
                cover_i = b.image and ("hc" .. b.id) or nil, cover_url = b.image, hc = b.id,
                -- "friends", "popular", or the title of the book of yours it's like
                because = because, rating = b.rating, ratings = b.ratings, description = desc or false }
        end
    end
    return out
end

--- Readers by name: { { id, username, name, books, followers } }.
function M.searchPeople(q, cb)
    q = tostring(q or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^@", "")
    if q == "" then return cb({}) end
    local key = "people:" .. q:lower()
    local hit = cached(key, 600)
    if hit then return cb(hit) end
    call([[query ($q: String!) { search(query: $q, query_type: "User", per_page: 20, page: 1) { ids } }]], { q = q }, function(data, why)
        if not data then return cb(nil, why) end
        cb(remember(key, data))
    end, function(data, token)
        local ids = idList(data.search and data.search.ids, 20)
        if #ids == 0 then return {} end
        local res, why = graphql(token, "query ($ids: [Int!]) { users(where: {id: {_in: $ids}}) { id username name books_count followers_count } }", { ids = ids })
        if not res then return nil, why end
        local by = {}
        for _i, u in ipairs(res.users or {}) do
            local who = userOf(u)
            if who then who.books, who.followers = u.books_count, u.followers_count by[u.id] = who end
        end
        local out, me = {}, uid()
        for _i, id in ipairs(ids) do if by[id] and id ~= me then out[#out + 1] = by[id] end end
        return out
    end)
end

--- Do you follow this reader (from what's kept)?
function M.isFollowing(user_id)
    for _i, p in ipairs(M.socialCached().people or {}) do if p.id == user_id then return true end end
    return false
end

--- Follow a reader, or stop. cb(true) once Hardcover has it (the friends
--- list is asked for again).
function M.follow(user_id, on, cb)
    cb = cb or function() end
    local q = on and "mutation ($id: Int!) { insert_followed_user(user_id: $id) { error id } }"
        or "mutation ($id: Int!) { delete_followed_user(user_id: $id) { error id } }"
    call(q, { id = user_id }, function(ok, why)
        if not ok then
            -- (a key made before 1.12.1 can read who you follow, not change it)
            if why == WHY.scope then why = _("This key can't follow or unfollow. Make a new one (Hardcover → ⋯ → Sign out, then sign in): the link now asks for that permission.") end
            return cb(nil, why)
        end
        if not on then
            -- gone from what's kept at once (the list is asked for again below)
            local soc = M.socialCached()
            for i = #(soc.people or {}), 1, -1 do if soc.people[i].id == user_id then table.remove(soc.people, i) end end
            M.social_gen = (M.social_gen or 0) + 1
        end
        M.social(function() cb(true) end, true)
    end, function(data)
        local r = data.insert_followed_user or data.delete_followed_user
        if not r or r.error then return nil, "refused" end
        return true
    end)
end

--- Take a book off your Hardcover shelves altogether (your rating, dates
--- and progress for it go too). cb(true).
function M.removeBook(user_book_id, book_id, cb)
    cb = cb or function() end
    call("mutation ($id: Int!) { delete_user_book(id: $id) { id } }", { id = user_book_id }, function(ok, why)
        if not ok then return cb(nil, why) end
        M.forget("shelf") M.forget("stats")
        if book_id then M.forget("book" .. book_id) end
        -- a file linked to it stays linked (it's still that book), without
        -- its place on a shelf; reading it won't put it back by itself
        local links, changed = get("links", {}), false
        for _file, link in pairs(links) do
            if link.entry == user_book_id or (book_id and link.id == book_id) then
                link.entry, link.read_id, link.sent = nil, nil, nil
                link.status, link.removed = 0, true
                changed = true
            end
        end
        if changed then set("links", links) M.links_gen = (M.links_gen or 0) + 1 end
        if book_id then mineChanged(book_id) end
        cb(true)
    end, function(data)
        if not data.delete_user_book then return nil, "refused" end
        return true
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
        -- (chosen on purpose: a file of it follows your reading again)
        local links, changed = get("links", {}), false
        for _file, link in pairs(links) do
            if link.id == book_id and link.removed then
                link.removed, link.entry, link.status = nil, data.id, data.status
                changed = true
            end
        end
        if changed then set("links", links) M.links_gen = (M.links_gen or 0) + 1 end
        mineChanged(book_id, status)
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
    M.links_gen = (M.links_gen or 0) + 1
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
    elseif job.kind == "rating" then
        -- (a rating needs the book on one of your shelves: Reading, if it
        -- isn't on one yet)
        local function rate(entry_id)
            M.rate(entry_id, job.value, link.id, function(entry)
                if entry then
                    local now = M.linkFor(job.file) or link
                    now.rating = entry.rating
                    M.setLink(job.file, now)
                end
                done(entry ~= nil)
            end)
        end
        if link.entry then return rate(link.entry) end
        M.setStatus(link.id, link.status or 2, function(entry)
            if not entry then return done(false) end
            local now = M.linkFor(job.file) or link
            now.entry, now.status = entry.id, entry.status
            M.setLink(job.file, now)
            rate(entry.id)
        end)
    else
        done(true)
    end
end

--- The status of a linked book, now or when next connected.
function M.status(file, status)
    local link = M.linkFor(file)
    -- (a book you took off your shelves isn't put back by reading it: only
    -- by choosing a shelf for it again)
    if not link or link.status == status or link.removed then return end
    queue("status", file, status)
    M.flush()
end

--- Your rating of a book (1..5, or nil: none), as your rating on
--- Hardcover, now or when next connected. A book not linked yet is linked
--- first when Hardcover certainly has it (the same title and author).
--- (Sent a few minutes after the last tap: a rating changed a couple of
--- times goes once, as it was left.)
M.RATING_SETTLE = 180
local rating_wait = {}
function M.rating(file, stars, title, author)
    if not M.signedIn() or not file then return end
    if rating_wait[file] then UIManager:unschedule(rating_wait[file]) end
    rating_wait[file] = function()
        rating_wait[file] = nil
        M.ratingNow(file, stars, title, author)
    end
    UIManager:scheduleIn(M.RATING_SETTLE, rating_wait[file])
end

function M.ratingNow(file, stars, title, author)
    if not M.signedIn() then return end
    local link = M.linkFor(file)
    if link and link.removed then return end
    if link then
        queue("rating", file, tonumber(stars) or 0)
        return M.flush()
    end
    if not (title and connected()) then return end
    M.match(title, author or "", function(hb, sure)
        if not (hb and sure) or M.linkFor(file) then return end
        M.setLink(file, { id = hb.id, title = hb.title, author = hb.author, pages = hb.pages })
        queue("rating", file, tonumber(stars) or 0)
        M.flush()
    end)
end

--- Hardcover's readers' rating of a linked book (kept a day), or nil; asks
--- for it again in the background when it's older, done(rating) if it
--- changed.
local rating_asked = {}
function M.communityRating(file, done)
    local link = file and M.linkFor(file)
    if not link then return nil end
    local fresh = link.hc_rating_at and os.time() - link.hc_rating_at < 86400
    if not fresh and not rating_asked[link.id] and M.signedIn() and connected() then
        rating_asked[link.id] = true
        call([[query ($id: Int!) { books_by_pk(id: $id) { rating ratings_count } }]], { id = link.id }, function(data)
            rating_asked[link.id] = nil
            local b = data and data.books_by_pk
            if type(b) ~= "table" then return end
            local now = M.linkFor(file)
            if not now then return end
            local r = tonumber(b.rating)
            local changed = now.hc_rating ~= r
            now.hc_rating, now.hc_rating_at = r, os.time()
            M.setLink(file, now)
            if changed and done then done(r) end
        end)
    end
    return tonumber(link.hc_rating)
end

--- Where you are in a linked book (0..1), now or when next connected.
function M.progress(file, percent)
    local link = M.linkFor(file)
    if not link or not percent or link.removed then return end
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

--- This device's reading history, sent to Hardcover in one go: the books
--- you've finished here (with the day you finished them) and the ones
--- you're in the middle of (with how far along). `list`: { { file, title,
--- author, done, finished_on, percent } }. Only a book that is certainly
--- the same one (the same title and author) is sent, and a book already on
--- one of your Hardcover shelves is left exactly as it is there. Runs in
--- the background; cb{ sent, already, unmatched, links = { file = link } }.
function M.sendHistory(list, cb)
    if not M.signedIn() then return cb(nil, say("signedout")) end
    if not connected() then return cb(nil, say("offline")) end
    local token, u = get("token"), uid()
    local todo = {}
    for _i, it in ipairs(list) do
        if #todo >= 60 then break end
        local link = M.linkFor(it.file)
        if not (link and link.status) then todo[#todo + 1] = { it = it, id = link and link.id } end
    end
    if #todo == 0 then return cb({ sent = 0, already = 0, unmatched = 0, links = {}, left = 0 }) end
    local left = math.max(0, #list - 60)
    Async().run(function()
        local ffiutil = require("ffi/util")
        local out = { sent = 0, already = 0, unmatched = 0, links = {}, left = left }
        for _i, t in ipairs(todo) do
            local it = t.it
            local id, title, author, pages = t.id, it.title, it.author, nil
            if not id then
                local short = tostring(it.title or ""):gsub(":.+", "")
                local found = graphql(token, [[query ($q: String!) { search(query: $q, query_type: "Book", per_page: 5, page: 1) { ids } }]],
                    { q = short .. " " .. (it.author or "") })
                local books = found and hydrate(token, idList(found.search and found.search.ids, 5)) or {}
                local a_last = norm(it.author):match("(%S+)$") or ""
                for _k, b in ipairs(books) do
                    local same_title = norm(b.title) == norm(it.title) or norm(b.title) == norm(short)
                    if same_title and a_last ~= "" and b.author and norm(b.author):find(a_last, 1, true) then
                        id, title, author, pages = b.id, b.title, b.author, b.pages
                        break
                    end
                end
            end
            if not id then
                out.unmatched = out.unmatched + 1
            else
                local have = graphql(token, [[query ($u: Int!, $b: Int!) {
                  user_books(where: {user_id: {_eq: $u}, book_id: {_eq: $b}}, limit: 1) { id status_id }
                }]], { u = u, b = id })
                local ub = have and first(have.user_books)
                local link = { id = id, title = title, author = author, pages = pages }
                if ub then
                    out.already = out.already + 1
                    link.entry, link.status = ub.id, ub.status_id
                elseif have then
                    local object = { book_id = id, status_id = it.done and 3 or 2 }
                    if it.done and it.finished_on then object.last_read_date = it.finished_on end
                    local res = graphql(token, [[mutation ($o: UserBookCreateInput!) {
                      insert_user_book(object: $o) { error user_book { id status_id } }
                    }]], { o = object })
                    local r = res and res.insert_user_book
                    if r and not r.error and r.user_book then
                        out.sent = out.sent + 1
                        link.entry, link.status = r.user_book.id, r.user_book.status_id
                        -- how far along, for a book you're in the middle of
                        if not it.done and it.percent and it.percent > 0 and pages and pages > 1 then
                            local page = math.max(1, math.min(pages - 1, math.floor(it.percent * pages + 0.5)))
                            graphql(token, [[mutation ($id: Int!, $p: Int!, $d: date) {
                              insert_user_book_read(user_book_id: $id, user_book_read: {progress_pages: $p, started_at: $d}) { error user_book_read { id } }
                            }]], { id = r.user_book.id, p = page, d = os.date("%Y-%m-%d") })
                            link.sent = it.percent
                        end
                    end
                end
                if link.status then out.links[it.file] = link end
            end
            ffiutil.usleep(350000) -- (gently: Hardcover counts requests by the minute)
        end
        return out
    end, function(ok, out, why)
        if not ok or type(out) ~= "table" then return cb(nil, say(ok and why or out)) end
        local links = get("links", {})
        for file, link in pairs(out.links) do links[file] = link end
        set("links", links)
        M.links_gen = (M.links_gen or 0) + 1
        M.forget("shelf") M.forget("stats")
        cb(out)
    end, 420)
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

-- Covers are kept at most this size (Hardcover's are often 1000 px or more:
-- each took ~100 ms to read on a Paperwhite, every time a page showed it).
local COVER_W, COVER_H = 360, 540

--- Make a fetched cover small (in a background process): written over itself
--- as a smaller JPEG. True if it was (or was already small).
local function shrink(path)
    local lfs = require("libs/libkoreader-lfs")
    local size = lfs.attributes(path, "size") or 0
    if size < 60000 then return true end
    local ok = pcall(function()
        local RenderImage = require("ui/renderimage")
        local bb = RenderImage:renderImageFile(path, false)
        if not bb then error("unreadable") end
        local w, h = bb:getWidth(), bb:getHeight()
        if w <= COVER_W and h <= COVER_H then
            -- (small already, just heavy: kept as it is)
            bb:free()
            return
        end
        local scale = math.min(COVER_W / w, COVER_H / h)
        local small = RenderImage:scaleBlitBuffer(bb, math.floor(w * scale + 0.5), math.floor(h * scale + 0.5), true)
        local tmp = path .. ".small"
        small:writeToFile(tmp, "jpg", 85)
        small:free()
        if (lfs.attributes(tmp, "size") or 0) > 0 then os.rename(tmp, path) else os.remove(tmp) end
    end)
    return ok
end
M._shrink = shrink

--- Covers fetched before they were made small: made small, a few at a
--- time in the background (once a session).
function M.shrinkOld()
    if M._shrunk then return end
    M._shrunk = true
    local lfs = require("libs/libkoreader-lfs")
    local dir = coverDir()
    local big = {}
    for f in lfs.dir(dir) do
        if f:match("^%d+%.jpg$") and (lfs.attributes(dir .. "/" .. f, "size") or 0) >= 60000 then
            big[#big + 1] = dir .. "/" .. f
            if #big >= 60 then break end
        end
    end
    if #big == 0 then return end
    Async().run(function()
        local n = 0
        for _i, p in ipairs(big) do if shrink(p) then n = n + 1 end end
        return n
    end, function() end, 120)
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
                if ok and res then
                    got = got + 1
                    shrink(w.path)
                end
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
